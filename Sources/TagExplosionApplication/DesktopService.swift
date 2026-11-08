import EInvoiceCore
import Foundation
import TagExplosionCore

/// Beide Desktopclients benutzen AppModel/FileEntry. Dieser Adapter übersetzt
/// ausschließlich den lokalen Nachrichtenvertrag in dieselben Aktionen.
@MainActor
public final class DesktopService {
    private var models: [String: AppModel] = [:]
    private var revisions: [String: Int] = [:]
    private var writing = false
    private var updating = false
    private var lookupCredentials = LookupCredentials()
    private var lookup: OnlineLookupService?
    private var candidates: [String: LookupCandidate] = [:]
    private var validationResults: [String: (URL, InvoiceValidationResult, EInvoiceDocument?)] = [:]
    private var validation: [String: ExternalToolRunner.Cancellation] = [:]
    private var infoJobs: [String: (id: UUID, task: Task<MediaInfoReport, Error>)] = [:]

    public init() { AppModel.applySafeMode() }

    public func handle(_ request: DesktopRequest) async -> DesktopResponse {
        do {
            let result = try await perform(request)
            return DesktopResponse(id: request.id, result: result, error: nil)
        } catch let error as DesktopFailure {
            return DesktopResponse(id: request.id, result: nil, error: error)
        } catch {
            return DesktopResponse(id: request.id, result: nil,
                                   error: DesktopFailure("operation_failed", error.localizedDescription))
        }
    }

    private func model(_ session: String) throws -> AppModel {
        guard !session.isEmpty, session.utf8.count <= 128 else { throw DesktopFailure("invalid_session", "Invalid session") }
        if let model = models[session] { return model }
        guard models.count < 32 else { throw DesktopFailure("too_many_windows", "Too many open windows") }
        let model = AppModel()
        models[session] = model
        revisions[session] = 0
        return model
    }

    private func entry(_ value: DesktopValue, in model: AppModel) throws -> FileEntry {
        guard let path = value["path"].text,
              let entry = model.entries.first(where: { $0.url.path == path }) else {
            throw DesktopFailure("entry_missing", "The file is no longer open")
        }
        return entry
    }

    private func targets(_ value: DesktopValue, in model: AppModel) -> [FileEntry] {
        let paths = Set(value["paths"].values.compactMap(\.text))
        return paths.isEmpty ? model.selectedEntries : model.entries.filter { paths.contains($0.url.path) }
    }

    private func requireRevision(_ value: DesktopValue, session: String) throws {
        guard value["revision"].integer == revisions[session] else {
            throw DesktopFailure("revision_changed", "The editor state changed; reload its current state before retrying")
        }
    }

    private func changed(_ session: String) { revisions[session, default: 0] += 1 }

    private func perform(_ request: DesktopRequest) async throws -> DesktopValue {
        let p = request.params
        if request.method == "hello" {
            return .object(["protocolVersion": .number(1), "pdfExtraction": .bool(EInvoiceReader.isPDFExtractionAvailable),
                            "coverConversion": .bool(CoverTools.isConversionAvailable)])
        }
        if request.method == "endUpdate" { updating = false; return .bool(true) }
        if request.method == "prepareUpdate" || request.method == "beginUpdate" {
            let allowed = !writing && !updating && validation.isEmpty && infoJobs.isEmpty && models.values.allSatisfy { !$0.hasSavingEntries && !$0.hasRunningExports && !$0.isLoading && !$0.isDestructiveActionLocked }
            if request.method == "beginUpdate", allowed { updating = true }
            return .bool(allowed)
        }
        if request.method == "lookupAuthorization" {
            let allowed = UserDefaults.standard.bool(forKey: "onlineServicesAllowed") && UserDefaults.standard.bool(forKey: "privacyAcknowledged")
            let source = p["source"].text.flatMap(LookupSource.init(rawValue:)) ?? candidates[p["id"].text ?? ""]?.source ?? .musicbrainz
            let account: DesktopValue = source == .discogs ? .string("discogs-token") : source == .acoustid ? .string("acoustid-client-key") : .null
            return .object(["allowed": .bool(allowed), "account": account])
        }
        if updating && !["state", "entry", "cover", "endUpdate", "cancel"].contains(request.method) {
            throw DesktopFailure("busy", "The application update is being installed")
        }
        if request.method == "close", models[request.session] == nil { return .object(["closed": .bool(true)]) }
        let model = try model(request.session)
        switch request.method {
        case "tools":
            return .object(["MediaInfo": .bool((try? MediaInfoReader.locateExecutable()) != nil),
                            "ExifTool": .bool((try? ExifTool.locateExecutable()) != nil),
                            "Calibre": .bool((try? EbookTool.locateCalibre()) != nil),
                            "ImageMagick": .bool(CoverTools.isConversionAvailable),
                            "Chromaprint": .bool((try? Fpcalc.locateExecutable()) != nil)])
        case "rulesSchema":
            return .object([
                "actions": .array(TagRule.Action.allCases.map { .object(["id": .string($0.rawValue), "title": .string(RuleLabels.action($0))]) }),
                "modes": .array(TagRule.CaseMode.allCases.map { .object(["id": .string($0.rawValue), "title": .string(RuleLabels.mode($0))]) }),
                "tests": .array(TagRuleCondition.Test.allCases.map { .object(["id": .string($0.rawValue), "title": .string(RuleLabels.test($0))]) }),
                "kinds": .array(RuleLabels.selectableKinds.map { .object(["id": $0.map { .string($0.rawValue) } ?? .string(""), "title": .string(RuleLabels.kind($0))]) }),
                "templates": .array(try TagRuleTemplate.allCases.map { .object(["id": .string($0.rawValue), "title": .string(RuleLabels.template($0)), "document": try .encoding($0.document)]) })
            ])
        case "lookupQuery": return try .encoding(LookupFileInfo.query(for: targets(p, in: model).map(\.lookupFileInfo)))
        case "batchCoverPreview":
            guard let cover = CoverToolActions.sharedCover(of: targets(p, in: model)) else { return .null }
            return .object(["data": try .encoding(cover.data), "mimeType": .string(cover.resolvedMimeType)])
        case "rawImageTags":
            let urls = targets(p, in: model).filter { $0.kind == .image }.map(\.url)
            return try await .encoding(BlockingWork.run { try ExifTool.readRawStringTags(urls: urls) })
        case "copyField":
            try requireRevision(p, session: request.session)
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            let selected = targets(p, in: model)
            let source = try required(p, "source"), target = try required(p, "target")
            if selected.allSatisfy({ $0.kind == .audio && !$0.isReadOnly && (MediaFormats.writableTagKeys(for: $0.url)?.contains(target) ?? true) }) {
                BatchAudioActions.copyValues(from: source, to: target, entries: selected)
            } else if selected.allSatisfy({ $0.kind == .image }), ["title", "description", "keywords", "creator", "copyright"].contains(target) {
                let urls = selected.map(\.url)
                let tags = try await BlockingWork.run { try ExifTool.readRawStringTags(urls: urls) }
                try requireRevision(p, session: request.session)
                guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", "A file operation is active") }
                for entry in selected {
                    guard let value = tags[entry.url.path]?[source], !value.isEmpty else { continue }
                    switch target {
                    case "title": entry.imageFields.title = value
                    case "description": entry.imageFields.description = value
                    case "keywords": entry.imageFields.keywords = value.splitCommaList()
                    case "creator": entry.imageFields.creator = value
                    case "copyright": entry.imageFields.copyright = value
                    default: break
                    }
                }
            } else { throw DesktopFailure("unsupported", "The selected field cannot be copied for these files") }
            changed(request.session)
        case "batchInfo":
            let selected = targets(p, in: model)
            guard let first = selected.first, selected.allSatisfy({ $0.kind == first.kind }) else { throw DesktopFailure("mixed_selection", "Select files of one type") }
            let descriptions = try selected.map(describe)
            var common: [String: DesktopValue] = [:]
            var mixed: [String] = []
            let keys = first.kind == .audio ? Set(selected.flatMap { $0.properties.map(\.key) }) : Set(descriptions.flatMap { $0["fields"].fields.keys }).union(first.kind == .image ? ["rating"] : [])
            for key in keys {
                let values = first.kind == .audio ? try selected.map { try DesktopValue.encoding($0.properties.filter { $0.key == key }.map(\.value)) } : descriptions.map { $0["fields"][key] }
                if values.allSatisfy({ $0 == values.first }) { common[key] = values.first ?? .null }
                else { mixed.append(key) }
            }
            let restrictions = selected.compactMap { MediaFormats.writableTagKeys(for: $0.url) }
            let writable = restrictions.first.map { first in restrictions.dropFirst().reduce(first) { $0.intersection($1) } }
            var supported = Set(descriptions[0]["fields"].fields.keys)
            if first.kind == .image { supported.insert("rating") }
            for description in descriptions where description["supportedFields"] != .null { supported.formIntersection(description["supportedFields"].values.compactMap(\.text)) }
            if first.kind == .ebook, selected.contains(where: { !EbookTool.supportsSeries(url: $0.url) }) { supported.subtract(["series", "seriesIndex"]) }
            return .object(["first": descriptions[0], "common": .object(common), "mixed": try .encoding(mixed), "sourceKeys": try .encoding(keys.sorted()), "writableKeys": try .encoding(writable?.sorted()), "supportedFields": try .encoding(supported.sorted()), "readOnly": .bool(selected.contains(where: \.isReadOnly)),
                            "loudnessKeys": try .encoding(selected.allSatisfy({ FixedFields.supportsLoudness($0.url) }) ? FixedFields.loudnessKeys.filter { ![FixedFields.r128TrackGain, FixedFields.r128AlbumGain].contains($0) || selected.allSatisfy({ FixedFields.supportsR128($0.url) }) } : [])])
        case "state": return try state(model, session: request.session)
        case "open":
            await model.open(urls: p["paths"].values.compactMap(\.text).map { URL(fileURLWithPath: $0) })
            changed(request.session)
        case "cancel":
            infoJobs[request.session]?.task.cancel()
            if p["operation"].text != "info" {
                model.cancelBatchSave(); model.cancelLoading(); validation[request.session]?.cancel()
            }
        case "select":
            let paths = Set(p["paths"].values.compactMap(\.text))
            model.selection = Set(model.entries.filter { paths.contains($0.url.path) }.map(\.url))
        case "filter":
            model.listSearch = p["search"].text ?? ""
            model.listKind = p["kind"].text.flatMap(MediaKind.init(rawValue:))
            model.listDirtyOnly = p["dirtyOnly"].flag; model.listErrorsOnly = p["errorsOnly"].flag
            model.listSort = p["sort"].text.flatMap(FileListSort.init(rawValue:)) ?? .input
        case "entry": return try describe(entry(p, in: model))
        case "imagePreview":
            let target = try entry(p, in: model)
            guard target.kind == .image else { return .null }
            let url = target.url
            let data: Data? = try await BlockingWork.run {
                if let bytes = try? DesktopFileInput.read(at: url),
                   ["image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp"].contains(Artwork.sniffMimeType(from: bytes) ?? "") { return bytes }
                return try ExifTool.readEmbeddedPreview(url: url)
            }
            guard let data else { return .null }
            return .object(["data": try .encoding(data), "mimeType": .string(Artwork.sniffMimeType(from: data) ?? "image/jpeg")])
        case "edit":
            try requireRevision(p, session: request.session)
            guard !model.isDestructiveActionLocked else { throw DesktopFailure("busy", "A file operation or decision is still active") }
            let target = try entry(p, in: model)
            try edit(target, values: p["values"])
            changed(request.session)
        case "cover":
            let target = try entry(p, in: model)
            let index = p["index"].integer ?? 0
            let data: Data?
            switch target.kind {
            case .audio: data = target.artworks.indices.contains(index) ? target.artworks[index].data : nil
            case .ebook: data = target.ebookCoverReplacement ?? target.ebookOriginalCover
            case .document: data = target.documentCover
            default: data = nil
            }
            return try .encoding(data)
        case "setCover", "removeCover", "folderCover", "convertCover":
            try requireRevision(p, session: request.session)
            let target = try entry(p, in: model)
            guard !target.isSaving, !model.isDestructiveActionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            try await changeCover(target, method: request.method, params: p) {
                try self.requireRevision(p, session: request.session)
                guard !target.isSaving, !model.isEditorInteractionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            }
            changed(request.session)
        case "save", "saveAll", "retry", "restore", "stripLayer", "import", "rename", "rulesApply", "shiftSubtitle", "export", "exportCover", "exportPlaylist", "saveRules", "exportChapters", "exportLRC", "exportValidation":
            guard !writing else { throw DesktopFailure("busy", "Another window is writing files") }
            try requireRevision(p, session: request.session)
            writing = true
            defer { writing = false }
            try await write(request.method, p, model: model, session: request.session)
            changed(request.session)
        case "revert":
            try requireRevision(p, session: request.session)
            guard !model.isDestructiveActionLocked, !model.hasSavingEntries else { throw DesktopFailure("busy", "A file operation is active") }
            for target in targets(p, in: model) { target.revert() }
            changed(request.session)
        case "remove":
            await model.remove(urls: targets(p, in: model).map(\.url)); changed(request.session)
        case "close":
            infoJobs[request.session]?.task.cancel()
            validation[request.session]?.cancel()
            while infoJobs[request.session] != nil || validation[request.session] != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            var permitted = false
            await model.requestWindowClose { permitted = true }
            if permitted { models.removeValue(forKey: request.session); revisions.removeValue(forKey: request.session); validationResults.removeValue(forKey: request.session) }
            return .object(["closed": .bool(permitted), "state": try state(model, session: request.session)])
        case "resolve":
            guard !writing else { throw DesktopFailure("busy", "Another window is writing files") }
            writing = true
            defer { writing = false }
            if let raw = p["dirty"].text {
                let decision: DirtyConflictDecision = raw == "save" ? .save : raw == "discard" ? .discard : .cancel
                await model.resolvePendingConflict(decision)
            }
            if case .bool(let approval) = p["external"] {
                if model.claimPendingExternalImport(approve: approval) { await model.resolveClaimedPendingExternalImport() }
            }
            if case .bool(let overwrite) = p["overwrite"] {
                if model.claimStaleWrite(write: overwrite) { await model.resolveClaimedStaleWrite() }
            }
            changed(request.session)
        case "history": return try .encoding(BackupHistory.versions(of: entry(p, in: model).url))
        case "historyDiff":
            let target = try entry(p, in: model)
            guard let version = BackupHistory.versions(of: target.url).first(where: { $0.id == p["id"].text }) else { throw DesktopFailure("version_missing", "Backup is no longer available") }
            return try .encoding(BackupHistory.diff(current: target.url, against: version))
        case "invoice":
            let url = try entry(p, in: model).url
            return try await .encoding(BlockingWork.run { try EInvoiceReader.read(url: url) })
        case "importChapters", "importLRC":
            try requireRevision(p, session: request.session)
            let target = try entry(p, in: model)
            guard target.kind == .audio, !target.isReadOnly, !model.isEditorInteractionLocked else { throw DesktopFailure("read_only", "The selected file cannot be edited") }
            let source = URL(fileURLWithPath: try required(p, "source"))
            if request.method == "importChapters" {
                guard target.supportsChapters else { throw DesktopFailure("unsupported", "This format cannot store chapters") }
                target.chapters = try ChapterList.load(from: source, totalLength: target.audio?.lengthMilliseconds)
            } else {
                let document = try LRC.load(from: source)
                target.syncedLyrics = document.lines
                if FixedFields.lyricsText(in: target.properties).isEmpty { target.properties = FixedFields.settingLyrics(LRC.plainText(document.lines), in: target.properties) }
            }
            changed(request.session)
        case "readRules":
            let data = try DesktopFileInput.read(at: URL(fileURLWithPath: required(p, "source")))
            _ = try JSONDecoder().decode(TagRuleDocument.self, from: data)
            return .string(String(decoding: data, as: UTF8.self))
        case "batchNumber", "batchTitles", "batchCover":
            try requireRevision(p, session: request.session)
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            let selected = targets(p, in: model)
            guard !selected.isEmpty, selected.allSatisfy({ $0.kind == .audio && !$0.isReadOnly }) else { throw DesktopFailure("mixed_selection", "Select writable audio files") }
            if request.method == "batchNumber" || request.method == "batchTitles" {
                let key = request.method == "batchNumber" ? "TRACKNUMBER" : "TITLE"
                guard selected.allSatisfy({ MediaFormats.writableTagKeys(for: $0.url)?.contains(key) ?? true }) else { throw DesktopFailure("unsupported", "This format cannot store the selected field") }
                if request.method == "batchNumber" { BatchAudioActions.renumber(selected) }
                else { for entry in selected { entry.setSingleValue("TITLE", BatchAudioActions.titleFromFilename(entry)) } }
            } else {
                guard selected.allSatisfy({ MediaFormats.supportsEmbeddedArtwork($0.url) }) else { throw DesktopFailure("unsupported", "The selected formats cannot all store artwork") }
                switch p["action"].text {
                case "set":
                    let data = try DesktopFileInput.read(at: URL(fileURLWithPath: required(p, "source")))
                    guard Artwork.sniffMimeType(from: data) != nil else { throw DesktopFailure("invalid_image", "Unsupported image data") }
                    let artwork = Artwork(data: data, pictureType: "Front Cover")
                    for entry in selected { entry.setFrontCover(artwork) }
                case "remove": for entry in selected { entry.removeFrontCover() }
                case "folder": model.alertMessage = CoverToolActions.report(CoverToolActions.applyFolderCover(selected), action: String(localized: "Ordner-Cover übernehmen"))
                case "convert":
                    let conversion = CoverTools.Conversion(maxPixelSize: p["maxPixelSize"].integer, format: p["format"].text.flatMap(CoverTools.OutputFormat.init(rawValue:)), stripMetadata: p["stripMetadata"].flag)
                    model.alertMessage = CoverToolActions.report(CoverToolActions.convert(selected, conversion), action: String(localized: "Cover-Werkzeuge"))
                default: throw DesktopFailure("invalid_parameter", "Unknown artwork action")
                }
            }
            changed(request.session)
        case "batchEdit":
            try requireRevision(p, session: request.session)
            guard !model.isDestructiveActionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            let selected = targets(p, in: model)
            guard Set(selected.map(\.kind)).count == 1 else { throw DesktopFailure("mixed_selection", "Select files of the same type") }
            var prepared: [(FileEntry, DesktopValue)] = []
            for target in selected {
                var value = try describe(target).fields
                if target.kind == .audio {
                    var properties = target.properties
                    let changes = try p["changes"].decode([String: [String]].self)
                    TagRuleFields.apply(changes, to: &properties)
                    value["properties"] = try .encoding(properties)
                } else {
                    var fields = value["fields"]?.fields ?? [:]
                    for (key, item) in p["changes"].fields where fields[key] != nil || (target.kind == .image && key == "rating") { fields[key] = item }
                    value["fields"] = .object(fields)
                }
                guard let trial = FileEntry(relocating: target, to: target.url) else { throw DesktopFailure("entry_missing", "The file is no longer open") }
                try edit(trial, values: .object(value))
                prepared.append((target, .object(value)))
            }
            for (target, value) in prepared { try edit(target, values: value) }
            changed(request.session)
        case "info":
            let url = try entry(p, in: model).url
            infoJobs[request.session]?.task.cancel()
            let id = UUID()
            let task = Task { try await MediaInfoCache.shared.read(url: url) }
            infoJobs[request.session] = (id, task)
            defer { if infoJobs[request.session]?.id == id { infoJobs.removeValue(forKey: request.session) } }
            do { return try await .encoding(task.value) }
            catch is CancellationError { return .object(["tracks": .array([]), "text": .string(""), "cancelled": .bool(true)]) }
        case "imageMetadata":
            let target = try entry(p, in: model)
            let url = target.url, sidecar = target.imageReading.sidecarURL
            return try await .encoding(BlockingWork.run { try ExifTool.readAllGroups(url: url, sidecarURL: sidecar) })
        case "rulesPreview":
            let document = try p["document"].decode(TagRuleDocument.self)
            return .array(try model.rulePlan(for: targets(p, in: model), document: document).map { .object(["path": .string($0.url.path), "kind": .string($0.kind.rawValue), "changes": try .encoding($0.changes)]) })
        case "parseFilename":
            try requireRevision(p, session: request.session)
            let outcome = model.applyFileNamePattern(try FilenamePattern(required(p, "pattern")), to: targets(p, in: model))
            changed(request.session)
            return .object(["applied": .number(Double(outcome.applied)), "unmatched": try .encoding(outcome.unmatched), "failed": try .encoding(outcome.failed), "state": try state(model, session: request.session)])
        case "renamePreview":
            let plan = model.renamePlan(for: targets(p, in: model), pattern: try FilenamePattern(required(p, "pattern")))
            return try .encoding(plan)
        case "check":
            let items = targets(p, in: model).compactMap(\.libraryCheckItem)
            let pattern = try p["pattern"].text.map(FilenamePattern.init)
            return try await .encoding(BlockingWork.run { LibraryCheck.run(items, pattern: pattern) })
        case "lookupSearch", "lookupDetails", "lookupPreview", "lookupApply":
            return try await online(request.method, p, model: model, session: request.session)
        case "validationCurrent", "validationReport":
            guard let (url, result, document) = validationResults[request.session] else { throw DesktopFailure("validation_missing", "Run validation first") }
            let current = try await BlockingWork.run { result.isCurrent(at: url) }
            if request.method == "validationCurrent" { return .bool(current) }
            guard current else { throw DesktopFailure("stale_validation", "The source has changed; validate it again before exporting a report") }
            return .string(InvoiceValidationPresentation.report(result: result, status: result.status, error: nil, url: url, document: document))
        case "validate":
            guard validation[request.session] == nil else { throw DesktopFailure("busy", "Validation is already running") }
            let target = try entry(p, in: model)
            let url = target.url
            let expected = target.diskStamp
            let cancellation = ExternalToolRunner.Cancellation()
            validation[request.session] = cancellation
            defer { validation.removeValue(forKey: request.session) }
            guard let root = ProcessInfo.processInfo.environment["TAGX_VALIDATION_BUNDLE"] else { throw DesktopFailure("validator_missing", "The validation package is not installed") }
            let pdf = ProcessInfo.processInfo.environment["TAGX_PDF_VALIDATION_BUNDLE"].map { URL(fileURLWithPath: $0) }
            let input = try await BlockingWork.run {
                try FileStamp.requireUnchanged(expected, at: url)
                return try InvoiceValidationInput.capture(at: url, cancellation: cancellation)
            }
            let result = try await BlockingWork.run {
                InvoiceValidationService.validate(input: input, bundle: URL(fileURLWithPath: root), pdfBundle: pdf, cancellation: cancellation)
            }
            let document = try? input.payload.document()
            validationResults[request.session] = (url, result, document)
            return .object(["result": try .encoding(result), "invoice": try .encoding(document), "current": .bool(result.isCurrent(at: url)),
                            "title": .string(InvoiceValidationPresentation.title(result.status, includesPDF: result.pdf != nil)),
                            "steps": .array(InvoiceValidationPresentation.steps(result).map { .object(["title": .string(InvoiceValidationPresentation.step($0.id, ruleSet: result.ruleSet)), "status": .string(InvoiceValidationPresentation.stepStatus($0.status))]) })])
        case "preferences":
            let allowed = [AppModel.safeModeDefaultsKey, AppModel.autoBackupDefaultsKey, AppModel.imageSidecarDefaultsKey, AppModel.id3v23DefaultsKey, "onlineServicesAllowed", "privacyAcknowledged"]
            for (key, value) in p["values"].fields where allowed.contains(key) {
                guard case .bool(let flag) = value else { throw DesktopFailure("invalid_setting", "Expected a boolean setting") }
                UserDefaults.standard.set(flag, forKey: key)
            }
            AppModel.applySafeMode()
            return .object(Dictionary(uniqueKeysWithValues: allowed.map { ($0, .bool(UserDefaults.standard.object(forKey: $0) == nil ? [AppModel.safeModeDefaultsKey, AppModel.autoBackupDefaultsKey].contains($0) : UserDefaults.standard.bool(forKey: $0))) }))
        case "clearAlert": model.alertMessage = nil
        default: throw DesktopFailure("unknown_method", "Unknown desktop operation")
        }
        return try state(model, session: request.session)
    }

    private func required(_ value: DesktopValue, _ key: String) throws -> String {
        guard let result = value[key].text, !result.isEmpty else { throw DesktopFailure("invalid_parameter", "Missing parameter: \(key)") }
        return result
    }

    private func state(_ model: AppModel, session: String) throws -> DesktopValue {
        let entries: [DesktopValue] = model.visibleEntries.map {
            .object(["path": .string($0.url.path), "name": .string($0.url.lastPathComponent), "title": .string($0.displayTitle),
                     "subtitle": .string($0.displaySubtitle), "kind": .string($0.kind.rawValue), "dirty": .bool($0.isDirty),
                     "saving": .bool($0.isSaving), "error": $0.lastError.map(DesktopValue.string) ?? .null])
        }
        var value: [String: DesktopValue] = ["revision": .number(Double(revisions[session] ?? 0)), "entries": .array(entries),
            "selection": try .encoding(model.selection.map(\.path)), "total": .number(Double(model.entries.count)),
            "hiddenSelection": .number(Double(model.hiddenSelectionCount)), "busy": .bool(writing),
            "loading": .bool(model.isLoading), "completed": .number(Double(model.loadingCompleted)), "count": .number(Double(model.loadingTotal)),
            "alert": model.alertMessage.map(DesktopValue.string) ?? .null, "dirty": .bool(model.hasDirtyEntries),
            "batch": .array(model.batchResults.map { .object(["path": .string($0.url.path), "status": .string(String(describing: $0.status)), "reason": .string($0.reason)]) })]
        if let conflict = model.pendingConflict {
            value["conflict"] = .object(["title": .string(conflict.title), "message": .string(conflict.displayedMessage)])
        }
        if let conflict = model.pendingExternalImport { value["externalImport"] = .string(conflict.displayedMessage) }
        if let conflict = model.pendingStaleWrite { value["staleWrite"] = .string(conflict.fileName) }
        return .object(value)
    }

    private func describe(_ entry: FileEntry) throws -> DesktopValue {
        var result: [String: DesktopValue] = ["path": .string(entry.url.path), "kind": .string(entry.kind.rawValue),
            "title": .string(entry.displayTitle), "dirty": .bool(entry.isDirty), "readOnly": .bool(entry.isReadOnly || entry.kind == .invoice),
            "supportsChapters": .bool(entry.supportsChapters), "supportsSyncedLyrics": .bool(entry.supportsSyncedLyrics),
            "supportsFilenamePatterns": .bool(entry.supportsFilenamePatterns)]
        switch entry.kind {
        case .audio:
            result["properties"] = try .encoding(entry.properties)
            result["writableKeys"] = try .encoding(MediaFormats.writableTagKeys(for: entry.url)?.sorted())
            result["supportsLyrics"] = .bool(FixedFields.supportsLyrics(entry.url))
            result["supportsLoudness"] = .bool(FixedFields.supportsLoudness(entry.url))
            result["supportsPodcast"] = .bool(FixedFields.supportsPodcast(entry.url))
            result["loudnessKeys"] = try .encoding(FixedFields.loudnessKeys.sorted())
            result["podcastKeys"] = try .encoding(FixedFields.podcastKeys.sorted())
            result["artworks"] = .array(entry.artworks.enumerated().map { i, art in
                .object(["index": .number(Double(i)), "mimeType": .string(art.resolvedMimeType), "pictureType": .string(art.pictureType), "description": .string(art.description), "analysis": (try? .encoding(CoverTools.analyze(art.data))) ?? .null, "summary": .string(CoverTools.analyze(art.data).summary), "issues": .array(CoverTools.analyze(art.data).issues.map { .string(CoverToolActions.issueText($0.code)) })])
            })
            result["audio"] = try .encoding(entry.audio)
            result["chapters"] = try .encoding(entry.chapters)
            result["lyricsLanguage"] = .string(entry.lyricsLanguage)
            result["syncedLyrics"] = try .encoding(entry.syncedLyrics)
            result["layers"] = try .encoding(entry.layers)
            if entry.videoNFO?.isEditable == true { result["videoNFO"] = try .encoding(entry.videoNFOFields) }
        case .image:
            result["fields"] = try .encoding(entry.imageFields)
            let destination = ExifTool.writeDestination(for: entry.url, preferSidecar: AppModel.imageSidecarPreferred)
            result["writeDestination"] = destination.isSidecar ? .string(ImagePresentation.destinationText(destination)) : .null
            result["ratingOptions"] = .array(RatingPicker.options(current: entry.imageFields.rating).map { .object(["value": $0.value.map { .number(Double($0)) } ?? .null, "label": .string($0.label)]) })
            result["sidecarFields"] = try .encoding(entry.imageReading.sidecarFields.map(\.rawValue))
            result["sidecar"] = entry.imageReading.sidecarURL.map { .string($0.path) } ?? .null
        case .ebook: result["fields"] = try .encoding(entry.ebookFields); result["supportsSeries"] = .bool(EbookTool.supportsSeries(url: entry.url)); result["supportsCover"] = .bool(EbookTool.supportsCover(url: entry.url)); result["hasCover"] = .bool((entry.ebookCoverReplacement ?? entry.ebookOriginalCover) != nil)
        case .document: result["fields"] = try .encoding(entry.documentFields); result["info"] = try .encoding(entry.documentInfo); result["supportedFields"] = try .encoding(DocumentTool.supportedFields(url: entry.url).map(\.rawValue)); result["hasCover"] = .bool(entry.documentCover != nil)
        case .invoice: result["invoice"] = try .encoding(entry.invoiceDocument)
        case .sidecar:
            switch entry.sidecarContents {
            case .nfo(let contents): result["fields"] = try .encoding(entry.nfoFields); result["subkind"] = .string("nfo"); result["readOnly"] = .bool(contents.isURLOnly); result["info"] = try .encoding(contents.info); result["urls"] = try .encoding(contents.urls)
            case .subtitle(let contents): result["fields"] = try .encoding(entry.subtitleFields); result["subkind"] = .string("subtitle"); result["supportedFields"] = try .encoding(contents.info.format == .vtt ? ["title", "language"] : [String]()); result["info"] = try .encoding(contents.info)
            case nil: break
            }
        case .playlist:
            result["fields"] = try .encoding(entry.playlistFields)
            result["supportedFields"] = try .encoding(PlaylistTool.supportedFields(url: entry.url).map(\.rawValue))
            result["playlist"] = try .encoding(entry.playlistContents)
        }
        return .object(result)
    }

    private func edit(_ entry: FileEntry, values: DesktopValue) throws {
        guard entry.kind != .invoice, !entry.isReadOnly || entry.videoNFO?.isEditable == true else { throw DesktopFailure("read_only", "This file is read-only") }
        // Erst vollständig dekodieren, dann übernehmen. Ein fehlerhaftes Feld
        // darf nicht die Hälfte einer mehrteiligen Eingabe verändern.
        switch entry.kind {
        case .audio:
            let properties = try values["properties"].decode([TagProperty].self)
            let chapters = try values["chapters"].decode([Chapter].self)
            let lyrics = try values["syncedLyrics"].decode([SyncedLyricLine].self)
            let nfo = try values["videoNFO"] == .null ? nil : values["videoNFO"].decode(NFOFields.self)
            if entry.isReadOnly {
                guard properties == entry.properties, chapters == entry.chapters, lyrics == entry.syncedLyrics,
                      values["lyricsLanguage"].text == entry.lyricsLanguage else { throw DesktopFailure("read_only", "The media metadata is read-only; only its NFO sidecar can be edited") }
            }
            entry.properties = properties; entry.chapters = chapters; entry.syncedLyrics = lyrics
            entry.lyricsLanguage = values["lyricsLanguage"].text ?? entry.lyricsLanguage
            if let nfo { entry.videoNFOFields = nfo }
        case .image: entry.imageFields = try values["fields"].decode(ImageCoreFields.self)
        case .ebook: entry.ebookFields = try values["fields"].decode(EbookCoreFields.self)
        case .document: entry.documentFields = try values["fields"].decode(DocumentCoreFields.self)
        case .sidecar:
            switch entry.sidecarContents {
            case .nfo: entry.nfoFields = try values["fields"].decode(NFOFields.self)
            case .subtitle: entry.subtitleFields = try values["fields"].decode(SubtitleEditableFields.self)
            case nil: throw DesktopFailure("read_only", "No editable metadata")
            }
        case .playlist: entry.playlistFields = try values["fields"].decode(PlaylistCoreFields.self)
        case .invoice: break
        }
    }

    private func changeCover(_ entry: FileEntry, method: String, params p: DesktopValue, beforeApply: () throws -> Void) async throws {
        guard !entry.isReadOnly, (entry.kind == .audio && MediaFormats.supportsEmbeddedArtwork(entry.url)) || (entry.kind == .ebook && EbookTool.supportsCover(url: entry.url)) else { throw DesktopFailure("read_only", "This format has no editable embedded cover") }
        let index = p["index"].integer ?? 0
        if method == "removeCover" {
            try beforeApply()
            guard entry.kind == .audio, entry.artworks.indices.contains(index) else { throw DesktopFailure("cover_missing", "No removable cover") }
            entry.artworks.remove(at: index); return
        }
        let artwork: Artwork
        if method == "convertCover" {
            guard entry.kind == .audio, entry.artworks.indices.contains(index) else { throw DesktopFailure("cover_missing", "No cover selected") }
            let source = entry.artworks[index]
            let conversion = CoverTools.Conversion(maxPixelSize: p["maxPixelSize"].integer,
                format: p["format"].text.flatMap(CoverTools.OutputFormat.init(rawValue:)),
                jpegQuality: 0.85, stripMetadata: p["stripMetadata"].flag)
            artwork = try await BlockingWork.run { try CoverTools.convert(source, conversion) }
        } else if method == "folderCover" {
            guard let cover = try FolderCover.load(in: entry.url.deletingLastPathComponent()) else { throw DesktopFailure("cover_missing", "No folder cover found") }
            artwork = cover
        } else {
            let path = try required(p, "source")
            let data = try DesktopFileInput.read(at: URL(fileURLWithPath: path))
            guard Artwork.sniffMimeType(from: data) != nil else { throw DesktopFailure("invalid_image", "Unsupported image data") }
            artwork = Artwork(data: data, pictureType: p["pictureType"].text ?? "Front Cover", description: p["description"].text ?? "")
        }
        try beforeApply()
        switch entry.kind {
        case .audio:
            if p["append"].flag { entry.artworks.append(artwork) }
            else if entry.artworks.indices.contains(index) { entry.artworks[index] = artwork }
            else { entry.setFrontCover(artwork) }
        case .ebook: entry.setEbookCover(artwork.data)
        default: throw DesktopFailure("read_only", "This format has no editable embedded cover")
        }
    }

    private func write(_ method: String, _ p: DesktopValue, model: AppModel, session: String) async throws {
        let selected = targets(p, in: model)
        switch method {
        case "exportValidation":
            guard let (url, result, document) = validationResults[session] else { throw DesktopFailure("validation_missing", "Run validation first") }
            guard try await BlockingWork.run({ result.isCurrent(at: url) }) else { throw DesktopFailure("stale_validation", "The source has changed; validate it again") }
            let report = InvoiceValidationPresentation.report(result: result, status: result.status, error: nil, url: url, document: document)
            await model.exportData(Data(report.utf8), to: URL(fileURLWithPath: try required(p, "destination")))
        case "exportChapters", "exportLRC":
            let target = try entry(p, in: model)
            let destination = URL(fileURLWithPath: try required(p, "destination"))
            let data: Data
            if method == "exportLRC" { data = Data(LRC.render(target.syncedLyrics).utf8) }
            else { data = destination.pathExtension.lowercased() == "json" ? try ChapterList.renderJSON(target.chapters) : Data(ChapterList.renderText(target.chapters).utf8) }
            await model.exportData(data, to: destination)
        case "save": _ = await model.saveEntries(selected.filter(\.isDirty))
        case "saveAll": await model.saveAll()
        case "retry": await model.retryFailedSaves()
        case "stripLayer": _ = try await model.stripLayer(entry: entry(p, in: model), kind: p["layer"].decode(TagLayerKind.self))
        case "restore":
            let target = try entry(p, in: model)
            guard p["confirmed"].flag, let version = BackupHistory.versions(of: target.url).first(where: { $0.id == p["id"].text }) else { throw DesktopFailure("confirmation_required", "Confirm the selected backup before restoring") }
            _ = await model.restoreVersion(version, for: target)
        case "import": try await model.importArchive(from: URL(fileURLWithPath: required(p, "source")))
        case "export": try await model.exportEntries(selected, to: URL(fileURLWithPath: required(p, "destination")))
        case "rename": try await model.renameFiles(selected, pattern: FilenamePattern(required(p, "pattern")))
        case "rulesApply": _ = try await model.applyRules(p["document"].decode(TagRuleDocument.self), to: selected)
        case "shiftSubtitle": _ = try await model.shiftSubtitle(entry: entry(p, in: model), seconds: Double(p["milliseconds"].integer ?? 0) / 1000)
        case "saveRules":
            let document = try p["document"].decode(TagRuleDocument.self)
            try document.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let destination = URL(fileURLWithPath: try required(p, "destination"))
            await model.exportData(try encoder.encode(document), to: destination)
            RuleFileHistory.remember(destination)
        case "exportCover":
            let target = try entry(p, in: model)
            let index = p["index"].integer ?? 0
            guard target.artworks.indices.contains(index) else { throw DesktopFailure("cover_missing", "No cover selected") }
            try await model.exportData(target.artworks[index].data, to: URL(fileURLWithPath: required(p, "destination")))
        case "exportPlaylist":
            guard let format = PlaylistFormat(rawValue: try required(p, "format")) else { throw DesktopFailure("invalid_format", "Invalid playlist format") }
            try await model.exportPlaylist(files: selected.map(\.url), to: URL(fileURLWithPath: required(p, "destination")), format: format, absolutePaths: p["absolutePaths"].flag, title: p["title"].text ?? "")
        default: break
        }
    }

    private func online(_ method: String, _ p: DesktopValue, model: AppModel, session: String) async throws -> DesktopValue {
        try OnlineLookupConsent.require(enabled: UserDefaults.standard.bool(forKey: "onlineServicesAllowed") && UserDefaults.standard.bool(forKey: "privacyAcknowledged"))
        var credentials = lookupCredentials
        let supplied = p["credentials"].fields
        if supplied["discogsToken"] != nil { credentials.discogsToken = supplied["discogsToken"]?.text }
        if supplied["acoustIDKey"] != nil { credentials.acoustIDKey = supplied["acoustIDKey"]?.text }
        if credentials != lookupCredentials { lookup = nil; lookupCredentials = credentials }
        if lookup == nil { lookup = OnlineLookupService(appVersion: "desktop", credentials: lookupCredentials) }
        guard let lookup else { throw DesktopFailure("lookup_unavailable", "Lookup is unavailable") }
        switch method {
        case "lookupSearch":
            let source = p["source"].text.flatMap(LookupSource.init(rawValue:)) ?? .musicbrainz
            let found: [LookupCandidate]
            if source == .acoustid { found = try await lookup.identify(fileURL: entry(p, in: model).url) }
            else { found = try await lookup.search(p["query"].decode(LookupQuery.self), source: source) }
            if candidates.count > 512 { candidates.removeAll() }
            for candidate in found { candidates[candidate.id] = candidate }
            return .array(try found.map { candidate in var value = try DesktopValue.encoding(candidate).fields; value["id"] = .string(candidate.id); return .object(value) })
        case "lookupDetails":
            guard let candidate = candidates[p["id"].text ?? ""] else { throw DesktopFailure("candidate_missing", "Search result expired") }
            let detailed = try await lookup.details(for: candidate)
            candidates[detailed.id] = detailed
            var value = try DesktopValue.encoding(detailed).fields; value["id"] = .string(detailed.id); return .object(value)
        default:
            guard let candidate = candidates[p["id"].text ?? ""] else { throw DesktopFailure("candidate_missing", "Search result expired") }
            let selected = targets(p, in: model).filter { $0.kind == .audio && !$0.isReadOnly }
            let assignments = TrackMatcher.assign(files: selected.map(\.lookupFileInfo), tracks: candidate.tracks)
            let options = LookupPlanOptions(includeIdentifiers: p["includeIdentifiers"] != .bool(false), overwriteExisting: p["overwriteExisting"].flag, includeCover: p["includeCover"].flag)
            let plans = zip(selected, assignments).map { target, assignment -> (FileEntry, LookupTrack?, LookupPlan) in
                let override = p["mapping"][target.url.path].integer
                let track = override.map { candidate.tracks.indices.contains($0) ? candidate.tracks[$0] : nil } ?? assignment.track
                return (target, track, LookupPlanner.plan(for: target.url, existing: target.properties, candidate: candidate, track: track, options: options))
            }
            if method == "lookupPreview" {
                return .array(try plans.map { target, track, plan in
                    .object(["path": .string(target.url.path), "trackIndex": track.flatMap { candidate.tracks.firstIndex(of: $0) }.map { .number(Double($0)) } ?? .number(-1),
                             "changes": try .encoding(plan.changes), "applicable": .bool(track != nil || selected.count == 1)])
                })
            }
            try requireRevision(p, session: session)
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            let cover = options.includeCover ? try await lookup.coverData(for: candidate) : nil
            try OnlineLookupConsent.require(enabled: UserDefaults.standard.bool(forKey: "onlineServicesAllowed") && UserDefaults.standard.bool(forKey: "privacyAcknowledged"))
            try requireRevision(p, session: session)
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", "A file operation is active") }
            let artwork = cover.map { Artwork(data: $0, mimeType: Artwork.sniffMimeType(from: $0) ?? "", pictureType: "Front Cover") }
            for (target, track, plan) in plans where track != nil || selected.count == 1 { target.applyLookup(plan, artwork: artwork) }
            changed(session)
            return try state(model, session: session)
        }
    }
}
