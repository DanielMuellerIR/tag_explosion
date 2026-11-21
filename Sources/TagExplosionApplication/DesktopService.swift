import EInvoiceCore
import Foundation
import TagExplosionCore

/// Beide Desktopclients benutzen AppModel/FileEntry. Dieser Adapter übersetzt
/// ausschließlich den lokalen Nachrichtenvertrag in dieselben Aktionen.
@MainActor
public final class DesktopService {
    private let preferences = AppPreferences()
    private var models: [String: AppModel] = [:]
    private var revisions: [String: Int] = [:]
    private var writing = false
    private var updating = false
    private var lookupCredentials = LookupCredentials()
    private var lookup: OnlineLookupService?
    private var candidates: [String: LookupCandidate] = [:]
    private var validationResults: [String: (URL, InvoiceValidationResult, EInvoiceDocument?)] = [:]
    private var validation: [String: ExternalToolRunner.Cancellation] = [:]
    private var infoJobs: [String: [UUID: Task<MediaInfoReport, Error>]] = [:]
    private var closingSessions: Set<String> = []
    private var closeWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    private final class CoverJob {
        let cancellation = ExternalToolRunner.Cancellation()
        var cancelled = false
        var completed = 0
        let total: Int
        init(total: Int) { self.total = total }
        func cancel() { cancelled = true; cancellation.cancel() }
    }
    private var coverJobs: [String: CoverJob] = [:]
    private let convertArtwork: @Sendable (Artwork, CoverTools.Conversion, ExternalToolRunner.Cancellation) throws -> Artwork

    public init() {
        convertArtwork = { try CoverTools.convert($0, $1, cancellation: $2) }
        AppModel.applySafeMode()
    }

    // Headless-Tests arbeiten ausschließlich mit selbst erzeugten Puffern.
    init(models: [String: AppModel], convertArtwork: @escaping @Sendable (Artwork, CoverTools.Conversion, ExternalToolRunner.Cancellation) throws -> Artwork) {
        self.models = models
        self.revisions = models.mapValues { _ in 0 }
        self.convertArtwork = convertArtwork
    }

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
        guard !session.isEmpty, session.utf8.count <= 128 else { throw DesktopFailure("invalid_session", String(localized: "Die Fenstersitzung ist ungültig.")) }
        if let model = models[session] { return model }
        guard models.count < 32 else { throw DesktopFailure("too_many_windows", String(localized: "Es sind zu viele Fenster geöffnet.")) }
        let model = AppModel(preferences: preferences)
        models[session] = model
        revisions[session] = 0
        return model
    }

    private func entry(_ value: DesktopValue, in model: AppModel) throws -> FileEntry {
        guard let path = value["path"].text,
              let entry = model.entries.first(where: { $0.url.path == path }) else {
            throw DesktopFailure("entry_missing", String(localized: "Die Datei ist nicht mehr geöffnet."))
        }
        return entry
    }

    private func targets(_ value: DesktopValue, in model: AppModel) -> [FileEntry] {
        let paths = Set(value["paths"].values.compactMap(\.text))
        return paths.isEmpty ? model.selectedEntries : model.entries.filter { paths.contains($0.url.path) }
    }

    private func requireRevision(_ value: DesktopValue, session: String) throws {
        guard value["revision"].integer == revisions[session] else {
            throw DesktopFailure("revision_changed", String(localized: "Der Editorstand hat sich geändert. Laden Sie den aktuellen Stand und versuchen Sie es erneut."))
        }
    }

    private func changed(_ session: String) { revisions[session, default: 0] += 1 }

    private func requireCurrentEditor(_ params: DesktopValue, model: AppModel, session: String) throws {
        guard models[session] === model else { throw DesktopFailure("entry_missing", String(localized: "Die Datei ist nicht mehr geöffnet.")) }
        try requireRevision(params, session: session)
        guard !updating, !closingSessions.contains(session), !model.isDestructiveActionLocked else {
            throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade."))
        }
    }

    private func cancelInfo(in session: String) {
        guard let jobs = infoJobs[session] else { return }
        for task in jobs.values { task.cancel() }
    }

    private func hasJobs(in session: String) -> Bool {
        infoJobs[session] != nil || validation[session] != nil || coverJobs[session] != nil
    }

    private func jobFinished(in session: String) {
        guard !hasJobs(in: session) else { return }
        closeWaiters.removeValue(forKey: session)?.resume()
    }

    private func close(_ model: AppModel, session: String) async throws -> DesktopValue {
        guard closingSessions.insert(session).inserted else {
            throw DesktopFailure("busy", String(localized: "Das Fenster wird bereits geschlossen."))
        }
        defer { closingSessions.remove(session) }
        cancelInfo(in: session)
        validation[session]?.cancel()
        coverJobs[session]?.cancel()
        if hasJobs(in: session) {
            await withCheckedContinuation { closeWaiters[session] = $0 }
        }
        var permitted = false
        await model.requestWindowClose { permitted = true }
        if permitted {
            models.removeValue(forKey: session)
            revisions.removeValue(forKey: session)
            validationResults.removeValue(forKey: session)
        }
        return .object(["closed": .bool(permitted), "state": try state(model, session: session)])
    }

    private func perform(_ request: DesktopRequest) async throws -> DesktopValue {
        let p = request.params
        if request.method == "hello" {
            return .object(["protocolVersion": .number(1), "pdfExtraction": .bool(EInvoiceReader.isPDFExtractionAvailable),
                            "coverConversion": .bool(CoverTools.isConversionAvailable)])
        }
        if request.method == "endUpdate" { updating = false; return .bool(true) }
        if request.method == "prepareUpdate" || request.method == "beginUpdate" {
            let allowed = !writing && !updating && closingSessions.isEmpty && coverJobs.isEmpty
                && validation.isEmpty && infoJobs.isEmpty && models.values.allSatisfy {
                    !$0.hasSavingEntries && !$0.hasRunningExports && !$0.isLoading && !$0.isDestructiveActionLocked
                }
            if request.method == "beginUpdate", allowed { updating = true }
            return .bool(allowed)
        }
        if request.method == "lookupAuthorization" {
            let allowed = preferences.onlineLookupEnabled
            let source = p["source"].text.flatMap(LookupSource.init(rawValue:)) ?? candidates[p["id"].text ?? ""]?.source ?? .musicbrainz
            let account: DesktopValue = source == .discogs ? .string("discogs-token") : source == .acoustid ? .string("acoustid-client-key") : .null
            return .object(["allowed": .bool(allowed), "account": account])
        }
        if updating && !["state", "entry", "cover", "endUpdate", "cancel"].contains(request.method) {
            throw DesktopFailure("busy", String(localized: "Das Update wird gerade installiert."))
        }
        if closingSessions.contains(request.session) && !["state", "entry", "cover", "cancel"].contains(request.method) {
            throw DesktopFailure("busy", String(localized: "Das Fenster wird bereits geschlossen."))
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
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            let selected = targets(p, in: model)
            let source = try required(p, "source"), target = try required(p, "target")
            if selected.allSatisfy({ $0.kind == .audio && !$0.isReadOnly && (MediaFormats.writableTagKeys(for: $0.url)?.contains(target) ?? true) }) {
                BatchAudioActions.copyValues(from: source, to: target, entries: selected)
            } else if selected.allSatisfy({ $0.kind == .image }), ["title", "description", "keywords", "creator", "copyright"].contains(target) {
                let urls = selected.map(\.url)
                let tags = try await BlockingWork.run { try ExifTool.readRawStringTags(urls: urls) }
                try requireCurrentEditor(p, model: model, session: request.session)
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
            } else { throw DesktopFailure("unsupported", String(localized: "Das ausgewählte Feld lässt sich für diese Dateien nicht kopieren.")) }
            changed(request.session)
        case "batchInfo":
            return try DesktopPresentation.batchInfo(targets(p, in: model),
                                                     preferSidecar: preferences.enabled(.imageSidecar))
        case "state": return try state(model, session: request.session)
        case "open":
            await model.open(urls: p["paths"].values.compactMap(\.text).map { URL(fileURLWithPath: $0) })
            changed(request.session)
        case "cancel":
            cancelInfo(in: request.session)
            if p["operation"].text != "info" {
                model.cancelBatchSave(); model.cancelLoading(); validation[request.session]?.cancel()
                coverJobs[request.session]?.cancel()
            }
        case "select":
            let paths = Set(p["paths"].values.compactMap(\.text))
            model.selection = Set(model.entries.filter { paths.contains($0.url.path) }.map(\.url))
        case "filter":
            model.listSearch = p["search"].text ?? ""
            model.listKind = p["kind"].text.flatMap(MediaKind.init(rawValue:))
            model.listDirtyOnly = p["dirtyOnly"].flag; model.listErrorsOnly = p["errorsOnly"].flag
            model.listSort = p["sort"].text.flatMap(FileListSort.init(rawValue:)) ?? .input
        case "entry":
            return try DesktopPresentation.describe(entry(p, in: model),
                                                    preferSidecar: preferences.enabled(.imageSidecar))
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
            guard !model.isDestructiveActionLocked else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation oder Entscheidung steht noch aus.")) }
            let target = try entry(p, in: model)
            try DesktopEdit.prepare(target, values: p["values"]).apply(to: target)
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
            guard !target.isSaving, !model.isDestructiveActionLocked else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            try await changeCover(target, method: request.method, params: p) {
                try self.requireCurrentEditor(p, model: model, session: request.session)
                guard !target.isSaving else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            }
            changed(request.session)
        case "save", "saveAll", "retry", "restore", "stripLayer", "import", "rename", "rulesApply", "shiftSubtitle", "export", "exportCover", "exportPlaylist", "saveRules", "exportChapters", "exportLRC", "exportValidation":
            guard !writing else { throw DesktopFailure("busy", String(localized: "Ein anderes Fenster schreibt gerade Dateien.")) }
            try requireRevision(p, session: request.session)
            writing = true
            defer { writing = false }
            try await write(request.method, p, model: model, session: request.session)
            changed(request.session)
        case "revert":
            try requireRevision(p, session: request.session)
            guard !model.isDestructiveActionLocked, !model.hasSavingEntries else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            for target in targets(p, in: model) { target.revert() }
            changed(request.session)
        case "remove":
            await model.remove(urls: targets(p, in: model).map(\.url)); changed(request.session)
        case "close": return try await close(model, session: request.session)
        case "resolve":
            guard !writing else { throw DesktopFailure("busy", String(localized: "Ein anderes Fenster schreibt gerade Dateien.")) }
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
        case "history":
            let url = try entry(p, in: model).url
            return try await .encoding(BlockingWork.run { BackupHistory.versions(of: url) })
        case "historyDiff":
            let url = try entry(p, in: model).url
            let id = p["id"].text
            return try await .encoding(BlockingWork.run {
                guard let version = BackupHistory.versions(of: url).first(where: { $0.id == id }) else {
                    throw DesktopFailure("version_missing", String(localized: "Die Sicherung ist nicht mehr verfügbar."))
                }
                return try BackupHistory.diff(current: url, against: version)
            })
        case "invoice":
            let url = try entry(p, in: model).url
            return try await .encoding(BlockingWork.run { try EInvoiceReader.read(url: url) })
        case "importChapters", "importLRC":
            try requireRevision(p, session: request.session)
            let target = try entry(p, in: model)
            guard target.kind == .audio, !target.isReadOnly, !model.isEditorInteractionLocked else { throw DesktopFailure("read_only", String(localized: "Die ausgewählte Datei lässt sich nicht bearbeiten.")) }
            let source = URL(fileURLWithPath: try required(p, "source"))
            if request.method == "importChapters" {
                guard target.supportsChapters else { throw DesktopFailure("unsupported", String(localized: "Dieses Format kann keine Kapitel speichern.")) }
                let length = target.audio?.lengthMilliseconds
                let chapters = try await BlockingWork.run {
                    try ChapterList.parse(DesktopFileInput.read(at: source), sourceName: source.lastPathComponent,
                                          totalLength: length)
                }
                try requireCurrentEditor(p, model: model, session: request.session)
                target.chapters = chapters
            } else {
                let document = try await BlockingWork.run {
                    try LRC.parse(DesktopFileInput.read(at: source), sourceName: source.lastPathComponent)
                }
                try requireCurrentEditor(p, model: model, session: request.session)
                target.syncedLyrics = document.lines
                if FixedFields.lyricsText(in: target.properties).isEmpty { target.properties = FixedFields.settingLyrics(LRC.plainText(document.lines), in: target.properties) }
            }
            changed(request.session)
        case "readRules":
            let url = URL(fileURLWithPath: try required(p, "source"))
            return try await BlockingWork.run {
                let data = try DesktopFileInput.read(at: url)
                _ = try JSONDecoder().decode(TagRuleDocument.self, from: data)
                return .string(String(decoding: data, as: UTF8.self))
            }
        case "batchNumber", "batchTitles", "batchCover":
            try requireRevision(p, session: request.session)
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            let selected = targets(p, in: model)
            guard !selected.isEmpty, selected.allSatisfy({ $0.kind == .audio && !$0.isReadOnly }) else { throw DesktopFailure("mixed_selection", String(localized: "Wählen Sie beschreibbare Audiodateien.")) }
            if request.method == "batchNumber" || request.method == "batchTitles" {
                let key = request.method == "batchNumber" ? "TRACKNUMBER" : "TITLE"
                guard selected.allSatisfy({ MediaFormats.writableTagKeys(for: $0.url)?.contains(key) ?? true }) else { throw DesktopFailure("unsupported", String(localized: "Dieses Format kann das ausgewählte Feld nicht speichern.")) }
                if request.method == "batchNumber" { BatchAudioActions.renumber(selected) }
                else { for entry in selected { entry.setSingleValue("TITLE", BatchAudioActions.titleFromFilename(entry)) } }
            } else {
                guard selected.allSatisfy({ MediaFormats.supportsEmbeddedArtwork($0.url) }) else { throw DesktopFailure("unsupported", String(localized: "Mindestens eines der ausgewählten Formate kann keine Cover speichern.")) }
                switch p["action"].text {
                case "set":
                    let url = URL(fileURLWithPath: try required(p, "source"))
                    let artwork = try await BlockingWork.run { try DesktopFileInput.artwork(at: url) }
                    try requireCurrentEditor(p, model: model, session: request.session)
                    for entry in selected { entry.setFrontCover(artwork) }
                case "remove": for entry in selected { entry.removeFrontCover() }
                case "folder":
                    let directories = selected.map { $0.url.deletingLastPathComponent() }
                    let covers = try await BlockingWork.run {
                        CoverToolActions.loadFolderCovers(directories, load: DesktopFileInput.folderCover)
                    }
                    try requireCurrentEditor(p, model: model, session: request.session)
                    let outcome = CoverToolActions.applyFolderCover(selected, covers: covers)
                    model.alertMessage = CoverToolActions.report(outcome, action: String(localized: "Ordner-Cover übernehmen"))
                case "convert":
                    let conversion = CoverTools.Conversion(maxPixelSize: p["maxPixelSize"].integer, format: p["format"].text.flatMap(CoverTools.OutputFormat.init(rawValue:)), stripMetadata: p["stripMetadata"].flag)
                    try await convertBatchCovers(selected, conversion, params: p, model: model, session: request.session)
                default: throw DesktopFailure("invalid_parameter", String(localized: "Die Cover-Aktion ist unbekannt."))
                }
            }
            changed(request.session)
        case "batchEdit":
            try requireRevision(p, session: request.session)
            guard !model.isDestructiveActionLocked else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            let selected = targets(p, in: model)
            guard Set(selected.map(\.kind)).count == 1 else { throw DesktopFailure("mixed_selection", String(localized: "Wählen Sie Dateien desselben Typs.")) }
            let prepared = try DesktopEdit.prepareBatch(selected, changes: p["changes"])
            for (entry, edit) in zip(selected, prepared) { edit.apply(to: entry) }
            changed(request.session)
        case "info":
            let url = try entry(p, in: model).url
            cancelInfo(in: request.session)
            let id = UUID()
            let task = Task { try await MediaInfoCache.shared.read(url: url) }
            infoJobs[request.session, default: [:]][id] = task
            defer {
                infoJobs[request.session]?.removeValue(forKey: id)
                if infoJobs[request.session]?.isEmpty == true { infoJobs.removeValue(forKey: request.session) }
                jobFinished(in: request.session)
            }
            do { return try await .encoding(task.value) }
            catch is CancellationError { return .object(["tracks": .array([]), "text": .string(""), "cancelled": .bool(true)]) }
        case "imageMetadata":
            let target = try entry(p, in: model)
            let url = target.url, sidecar = target.imageReading.sidecarURL
            return try await .encoding(BlockingWork.run { try ExifTool.readAllGroups(url: url, sidecarURL: sidecar) })
        case "rulesPreview":
            let document = try p["document"].decode(TagRuleDocument.self)
            let inputs = model.ruleInputs(for: targets(p, in: model))
            let plans = try await BlockingWork.run { try AppModel.rulePlan(for: inputs, document: document) }
            return .array(try plans.map { plan in
                .object(["path": .string(plan.url.path), "kind": .string(plan.kind.rawValue),
                         "changes": try .encoding(plan.changes)])
            })
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
            guard let (url, result, document) = validationResults[request.session] else { throw DesktopFailure("validation_missing", String(localized: "Prüfen Sie zuerst die Rechnung.")) }
            let current = try await BlockingWork.run { result.isCurrent(at: url) }
            if request.method == "validationCurrent" { return .bool(current) }
            guard current else { throw DesktopFailure("stale_validation", String(localized: "Die Quelldatei hat sich geändert. Prüfen Sie sie vor dem Berichtsexport erneut.")) }
            return .string(InvoiceValidationPresentation.report(result: result, status: result.status, error: nil, url: url, document: document))
        case "validate":
            guard validation[request.session] == nil else { throw DesktopFailure("busy", String(localized: "Die Rechnungsprüfung läuft bereits.")) }
            let target = try entry(p, in: model)
            let url = target.url
            let expected = target.diskStamp
            let cancellation = ExternalToolRunner.Cancellation()
            validation[request.session] = cancellation
            defer {
                validation.removeValue(forKey: request.session)
                jobFinished(in: request.session)
            }
            guard let root = ProcessInfo.processInfo.environment["TAGX_VALIDATION_BUNDLE"] else { throw DesktopFailure("validator_missing", String(localized: "Das Paket zur Rechnungsprüfung ist nicht installiert.")) }
            let pdf = ProcessInfo.processInfo.environment["TAGX_PDF_VALIDATION_BUNDLE"].map { URL(fileURLWithPath: $0) }
            let input = try await BlockingWork.run {
                try FileStamp.requireUnchanged(expected, at: url)
                return try InvoiceValidationInput.capture(at: url, cancellation: cancellation)
            }
            let result = try await BlockingWork.run {
                InvoiceValidationService.validate(input: input, bundle: URL(fileURLWithPath: root), pdfBundle: pdf, cancellation: cancellation)
            }
            let (document, current) = try await BlockingWork.run {
                (try? input.payload.document(), result.isCurrent(at: url))
            }
            validationResults[request.session] = (url, result, document)
            return .object(["result": try .encoding(result), "invoice": try .encoding(document), "current": .bool(current),
                            "title": .string(InvoiceValidationPresentation.title(result.status, includesPDF: result.pdf != nil)),
                            "steps": .array(InvoiceValidationPresentation.steps(result).map { .object(["title": .string(InvoiceValidationPresentation.step($0.id, ruleSet: result.ruleSet)), "status": .string(InvoiceValidationPresentation.stepStatus($0.status))]) })])
        case "preferences":
            return try applyPreferences(p["values"].fields)
        case "clearAlert": model.alertMessage = nil
        default: throw DesktopFailure("unknown_method", String(localized: "Der Vorgang ist unbekannt."))
        }
        return try state(model, session: request.session)
    }

    private func applyPreferences(_ values: [String: DesktopValue]) throws -> DesktopValue {
        let changes: [(AppPreferences.Setting, Bool)] = try values.compactMap { key, value in
            guard let setting = AppPreferences.Setting(rawValue: key) else { return nil }
            guard case .bool(let flag) = value else {
                throw DesktopFailure("invalid_setting", String(localized: "Die Einstellung erwartet einen Ein- oder Aus-Wert."))
            }
            return (setting, flag)
        }
        for (setting, flag) in changes { preferences.set(flag, for: setting) }
        if changes.contains(where: { $0.0 == .safeMode }) { AppModel.applySafeMode() }
        return .object(Dictionary(uniqueKeysWithValues: AppPreferences.Setting.allCases.map {
            ($0.rawValue, .bool(preferences.enabled($0)))
        }))
    }

    private func required(_ value: DesktopValue, _ key: String) throws -> String {
        guard let result = value[key].text, !result.isEmpty else { throw DesktopFailure("invalid_parameter", String(localized: "Der Parameter \(key) fehlt.")) }
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
            "hiddenSelection": .number(Double(model.hiddenSelectionCount)), "busy": .bool(writing || coverJobs[session] != nil),
            "loading": .bool(model.isLoading), "completed": .number(Double(model.loadingCompleted)), "count": .number(Double(model.loadingTotal)),
            "alert": model.alertMessage.map(DesktopValue.string) ?? .null, "dirty": .bool(model.hasDirtyEntries),
            "batch": .array(model.batchResults.map { .object(["path": .string($0.url.path), "status": .string(String(describing: $0.status)), "reason": .string($0.reason)]) })]
        if let job = coverJobs[session] {
            value["coverCompleted"] = .number(Double(job.completed))
            value["coverTotal"] = .number(Double(job.total))
        }
        if let conflict = model.pendingConflict {
            value["conflict"] = .object(["title": .string(conflict.title), "message": .string(conflict.displayedMessage)])
        }
        if let conflict = model.pendingExternalImport { value["externalImport"] = .string(conflict.displayedMessage) }
        if let conflict = model.pendingStaleWrite { value["staleWrite"] = .string(conflict.fileName) }
        return .object(value)
    }

    private func convertBatchCovers(_ entries: [FileEntry], _ conversion: CoverTools.Conversion, params p: DesktopValue, model: AppModel, session: String) async throws {
        guard coverJobs[session] == nil, !model.isDestructiveActionLocked,
              entries.allSatisfy({ !$0.isSaving }) else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation oder Entscheidung steht noch aus.")) }
        let sources = entries.map { ($0, $0.frontCover) }
        let job = CoverJob(total: sources.count)
        coverJobs[session] = job
        defer {
            coverJobs.removeValue(forKey: session)
            jobFinished(in: session)
        }
        let convert = convertArtwork
        var prepared: [(FileEntry, Artwork)] = []
        var outcome = CoverToolActions.Outcome()
        for (entry, source) in sources {
            try Task.checkCancellation()
            guard !job.cancelled else { throw CancellationError() }
            if let source {
                let cancellation = job.cancellation
                let result = try await BlockingWork.run { Result { try convert(source, conversion, cancellation) } }
                try Task.checkCancellation()
                guard !job.cancelled else { throw CancellationError() }
                try requireRevision(p, session: session)
                guard !model.isDestructiveActionLocked, !entry.isSaving else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
                switch result {
                case .success(let converted):
                    if converted.data == source.data { outcome.unchanged += 1 }
                    else { prepared.append((entry, converted)); outcome.changed += 1 }
                case .failure(let error):
                    outcome.errors.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
                }
            } else { outcome.skipped += 1 }
            job.completed += 1
        }
        // Keine Teilübernahme: erst nach allen Wartezeiten den Puffer freigeben.
        try requireRevision(p, session: session)
        guard !job.cancelled else { throw CancellationError() }
        guard !model.isDestructiveActionLocked, entries.allSatisfy({ entry in
            !entry.isSaving && model.entries.contains(where: { $0 === entry })
        }) else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
        for (entry, artwork) in prepared { entry.setFrontCover(artwork) }
        model.alertMessage = CoverToolActions.report(outcome, action: String(localized: "Cover-Werkzeuge"))
    }

    private func changeCover(_ entry: FileEntry, method: String, params p: DesktopValue, beforeApply: () throws -> Void) async throws {
        guard !entry.isReadOnly, (entry.kind == .audio && MediaFormats.supportsEmbeddedArtwork(entry.url)) || (entry.kind == .ebook && EbookTool.supportsCover(url: entry.url)) else { throw DesktopFailure("read_only", String(localized: "Dieses Format unterstützt kein bearbeitbares eingebettetes Cover.")) }
        let index = p["index"].integer ?? 0
        if method == "removeCover" {
            try beforeApply()
            guard entry.kind == .audio, entry.artworks.indices.contains(index) else { throw DesktopFailure("cover_missing", String(localized: "Die Datei enthält kein löschbares Cover.")) }
            entry.artworks.remove(at: index); return
        }
        let artwork: Artwork
        if method == "convertCover" {
            guard entry.kind == .audio, entry.artworks.indices.contains(index) else { throw DesktopFailure("cover_missing", String(localized: "Wählen Sie ein Cover aus.")) }
            let source = entry.artworks[index]
            let conversion = CoverTools.Conversion(maxPixelSize: p["maxPixelSize"].integer,
                format: p["format"].text.flatMap(CoverTools.OutputFormat.init(rawValue:)),
                jpegQuality: 0.85, stripMetadata: p["stripMetadata"].flag)
            artwork = try await BlockingWork.run { try CoverTools.convert(source, conversion) }
        } else if method == "folderCover" {
            let directory = entry.url.deletingLastPathComponent()
            guard let cover = try await BlockingWork.run({ try DesktopFileInput.folderCover(directory) }) else {
                throw DesktopFailure("cover_missing", String(localized: "Im Ordner wurde kein Cover gefunden."))
            }
            artwork = cover
        } else {
            let url = URL(fileURLWithPath: try required(p, "source"))
            let type = p["pictureType"].text ?? "Front Cover"
            let description = p["description"].text ?? ""
            artwork = try await BlockingWork.run {
                try DesktopFileInput.artwork(at: url, pictureType: type, description: description)
            }
        }
        try beforeApply()
        switch entry.kind {
        case .audio:
            if p["append"].flag { entry.artworks.append(artwork) }
            else if entry.artworks.indices.contains(index) { entry.artworks[index] = artwork }
            else { entry.setFrontCover(artwork) }
        case .ebook: entry.setEbookCover(artwork.data)
        default: throw DesktopFailure("read_only", String(localized: "Dieses Format unterstützt kein bearbeitbares eingebettetes Cover."))
        }
    }

    private func write(_ method: String, _ p: DesktopValue, model: AppModel, session: String) async throws {
        let selected = targets(p, in: model)
        switch method {
        case "exportValidation":
            guard let (url, result, document) = validationResults[session] else { throw DesktopFailure("validation_missing", String(localized: "Prüfen Sie zuerst die Rechnung.")) }
            guard try await BlockingWork.run({ result.isCurrent(at: url) }) else { throw DesktopFailure("stale_validation", String(localized: "Die Quelldatei hat sich geändert. Prüfen Sie sie erneut.")) }
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
            let url = target.url
            let id = p["id"].text
            guard p["confirmed"].flag, let version = try await BlockingWork.run({
                BackupHistory.versions(of: url).first(where: { $0.id == id })
            }) else { throw DesktopFailure("confirmation_required", String(localized: "Bestätigen Sie die ausgewählte Sicherung vor der Wiederherstellung.")) }
            try requireCurrentEditor(p, model: model, session: session)
            _ = await model.restoreVersion(version, for: target)
        case "import": try await model.importArchive(from: URL(fileURLWithPath: required(p, "source")))
        case "export": try await model.exportEntries(selected, to: URL(fileURLWithPath: required(p, "destination")))
        case "rename": try await model.renameFiles(selected, pattern: FilenamePattern(required(p, "pattern")))
        case "rulesApply":
            let document = try p["document"].decode(TagRuleDocument.self)
            let inputs = model.ruleInputs(for: selected)
            let plans = await model.prepareRules(document, inputs: inputs)
            try requireCurrentEditor(p, model: model, session: session)
            if let plans { _ = await model.applyPreparedRules(plans, matching: inputs, to: selected) }
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
            guard target.artworks.indices.contains(index) else { throw DesktopFailure("cover_missing", String(localized: "Wählen Sie ein Cover aus.")) }
            try await model.exportData(target.artworks[index].data, to: URL(fileURLWithPath: required(p, "destination")))
        case "exportPlaylist":
            guard let format = PlaylistFormat(rawValue: try required(p, "format")) else { throw DesktopFailure("invalid_format", String(localized: "Das Playlist-Format ist ungültig.")) }
            try await model.exportPlaylist(files: selected.map(\.url), to: URL(fileURLWithPath: required(p, "destination")), format: format, absolutePaths: p["absolutePaths"].flag, title: p["title"].text ?? "")
        default: break
        }
    }

    private func online(_ method: String, _ p: DesktopValue, model: AppModel, session: String) async throws -> DesktopValue {
        try OnlineLookupConsent.require(enabled: preferences.onlineLookupEnabled)
        var credentials = lookupCredentials
        let supplied = p["credentials"].fields
        if supplied["discogsToken"] != nil { credentials.discogsToken = supplied["discogsToken"]?.text }
        if supplied["acoustIDKey"] != nil { credentials.acoustIDKey = supplied["acoustIDKey"]?.text }
        if credentials != lookupCredentials { lookup = nil; lookupCredentials = credentials }
        if lookup == nil { lookup = OnlineLookupService(appVersion: "desktop", credentials: lookupCredentials) }
        guard let lookup else { throw DesktopFailure("lookup_unavailable", String(localized: "Die Online-Suche ist nicht verfügbar.")) }
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
            guard let candidate = candidates[p["id"].text ?? ""] else { throw DesktopFailure("candidate_missing", String(localized: "Das Suchergebnis ist nicht mehr verfügbar.")) }
            let detailed = try await lookup.details(for: candidate)
            candidates[detailed.id] = detailed
            var value = try DesktopValue.encoding(detailed).fields; value["id"] = .string(detailed.id); return .object(value)
        default:
            guard let candidate = candidates[p["id"].text ?? ""] else { throw DesktopFailure("candidate_missing", String(localized: "Das Suchergebnis ist nicht mehr verfügbar.")) }
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
            guard !model.isEditorInteractionLocked else { throw DesktopFailure("busy", String(localized: "Eine Dateioperation läuft gerade.")) }
            let cover = options.includeCover ? try await lookup.coverData(for: candidate) : nil
            try OnlineLookupConsent.require(enabled: preferences.onlineLookupEnabled)
            try requireCurrentEditor(p, model: model, session: session)
            let artwork = cover.map { Artwork(data: $0, mimeType: Artwork.sniffMimeType(from: $0) ?? "", pictureType: "Front Cover") }
            for (target, track, plan) in plans where track != nil || selected.count == 1 { target.applyLookup(plan, artwork: artwork) }
            changed(session)
            return try state(model, session: session)
        }
    }
}
