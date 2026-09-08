// Umbenennen von Dateien nach einem Muster: erst planen (Vorschau mit
// Konflikten), dann ausführen. Der Plan ist ein reiner Wert und kann in
// App und CLI gleich angezeigt werden.
//
// Warum hier KEINE Papierkorb-Sicherung (`TrashBackup`) läuft: Umbenennen
// ändert kein einziges Byte des Inhalts, nur den Verzeichniseintrag —
// dieselbe `rename(2)`-Operation, mit der `AtomicFileRewrite` eine fertig
// geprüfte Kopie einsetzt. Die Regel „Sicherung vor jeder Mutation" aus
// knowledge/dateisicherheit-schreibwege.md schützt vor kaputten oder
// ungewollt veränderten Inhalten; ein Umbenennen ist verlustfrei durch
// Zurückbenennen umkehrbar. Eine Kopie im Papierkorb wäre dagegen bei großen
// Ordnern reine Plattenlast. Was stattdessen schützt: `moveItem` überschreibt
// nie (ein vorhandenes Ziel ist ein Fehler), und der Plan lehnt jede
// Kollision vorher ab. Der einzige Schreibweg, der Inhalte anfasst — Tags
// aus dem Dateinamen — läuft weiterhin über Sicherung + atomaren Austausch.
import Foundation

public enum FileRenamer {

    /// Sidecar-Pfad und neuer Dateiname im selben Ordner.
    public struct SidecarMove: Sendable, Codable, Equatable {
        public var source: String
        public var target: String
        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }
        public var sourceURL: URL { URL(fileURLWithPath: source) }
        public var targetURL: URL { sourceURL.deletingLastPathComponent().appendingPathComponent(target) }
    }

    /// Eine geplante Umbenennung mit Ergebnis der Prüfung.
    public struct Item: Sendable, Codable, Equatable {
        public enum Status: String, Sendable, Codable {
            /// Neuer Name unterscheidet sich; Umbenennen ist möglich.
            case rename
            /// Alter und neuer Name sind gleich; nichts zu tun.
            case unchanged
            /// Umbenennen wird verweigert; Grund in `reason`.
            case conflict
        }

        public var source: String
        /// Neuer Name (nur Dateiname, gleicher Ordner); leer bei leerem Muster-Ergebnis.
        public var target: String
        public var status: Status
        /// Konfliktgrund in Klartext (englisch, wie alle Core-Fehlertexte).
        public var reason: String?
        /// Namensgebundene Sidecar, die im selben Zug auf den neuen Stamm
        /// umbenannt wird (Pfad): `<name>.xmp` neben einem Bild, `<name>.lrc`
        /// neben Audio, `<name>.nfo` neben einem Video (siehe
        /// `companionSidecars`). nil = keine Sidecar, Datei ist selbst eine
        /// `.xmp`, oder ein früherer Eintrag des Plans nimmt dieselbe Sidecar
        /// schon mit (RAW+JPEG-Paar).
        public var sidecarSource: String?
        /// Neuer Name der Sidecar (nur Dateiname, gleicher Ordner).
        public var sidecarTarget: String?
        /// Weitere Sidecars, etwa LRC neben einer MP4 mit NFO. Optional hält
        /// gespeicherte Pläne ohne dieses Feld weiterhin lesbar.
        public var additionalSidecars: [SidecarMove]?
        public var sidecarMoves: [SidecarMove] {
            let first = sidecarSource.flatMap { source in
                sidecarTarget.map { SidecarMove(source: source, target: $0) }
            }
            return first.map { [$0] + (additionalSidecars ?? []) } ?? (additionalSidecars ?? [])
        }

        public init(source: String, target: String, status: Status, reason: String? = nil,
                    sidecarSource: String? = nil, sidecarTarget: String? = nil,
                    additionalSidecars: [SidecarMove]? = nil) {
            self.source = source
            self.target = target
            self.status = status
            self.reason = reason
            self.additionalSidecars = additionalSidecars
            self.sidecarSource = sidecarSource
            self.sidecarTarget = sidecarTarget
        }

        public var sourceURL: URL { URL(fileURLWithPath: source) }
        public var targetURL: URL {
            URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent(target)
        }
        public var sidecarSourceURL: URL? { sidecarSource.map { URL(fileURLWithPath: $0) } }
        public var sidecarTargetURL: URL? {
            sidecarTarget.map { sourceURL.deletingLastPathComponent().appendingPathComponent($0) }
        }
    }

    /// Vorschau: alle Einträge in Eingabereihenfolge.
    public struct Plan: Sendable, Codable, Equatable {
        public var items: [Item]

        public var hasConflicts: Bool { items.contains { $0.status == .conflict } }
        public var renames: [Item] { items.filter { $0.status == .rename } }
        public var conflicts: [Item] { items.filter { $0.status == .conflict } }
    }

    /// Eingabe für die Planung: Datei plus die Feldwerte für das Muster.
    public struct Request: Sendable {
        public var url: URL
        public var fields: [String: String]

        public init(url: URL, fields: [String: String]) {
            self.url = url
            self.fields = fields
        }
    }

    /// Ergebnis einer ausgeführten Umbenennung.
    public struct Outcome: Sendable, Codable, Equatable {
        public var source: String
        public var target: String
        /// nil = umbenannt; sonst der Fehlertext.
        public var error: String?
        /// Neuer Pfad der mit umbenannten Sidecar (XMP/LRC/NFO); nil = keine dabei.
        public var sidecarTarget: String?
        /// Umbenannt, aber ein Nebenweg (Sicherungs-Journal) scheiterte;
        /// nil = alles in Ordnung.
        public var warning: String?
        public var additionalSidecarTargets: [String]?
        public var sidecarTargets: [String] {
            (sidecarTarget.map { [$0] } ?? []) + (additionalSidecarTargets ?? [])
        }

        public init(source: String, target: String, error: String? = nil, sidecarTarget: String? = nil,
                    warning: String? = nil, additionalSidecarTargets: [String]? = nil) {
            self.source = source
            self.target = target
            self.error = error
            self.sidecarTarget = sidecarTarget
            self.warning = warning
            self.additionalSidecarTargets = additionalSidecarTargets
        }

        public var succeeded: Bool { error == nil }
    }

    /// Prüft, ob der Datenträger eines Ordners Groß-/Kleinschreibung
    /// unterscheidet. Unbekannt gilt als „nicht unterscheidend" — das ist die
    /// strengere Annahme und meldet im Zweifel einen Konflikt mehr.
    public static func isCaseSensitive(directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
    }

    /// Plant die Umbenennung. Es wird nichts verändert.
    ///
    /// Konflikte, die den Eintrag stoppen:
    /// - Das Muster liefert einen leeren Namen (alle Felder leer).
    /// - Zwei Dateien bekämen denselben Namen (auf Datenträgern ohne
    ///   Unterscheidung der Schreibweise auch „song" gegen „Song").
    /// - Am Zielnamen liegt schon eine andere Datei. Ausnahme: Das Ziel ist
    ///   dieselbe Datei in anderer Schreibweise (song.mp3 → Song.mp3) — das
    ///   ist eine gewöhnliche Umbenennung, kein Konflikt.
    /// - Liegt neben einem Bild eine XMP-Sidecar `<name>.xmp`, wandert sie
    ///   im selben Eintrag auf `<neuername>.xmp`; ist DIESER Name belegt oder
    ///   schon vergeben, gilt der ganze Eintrag als Konflikt. Sonst verlöre
    ///   das Bild seine Sidecar-Werte (Lightroom findet sie nur namensgleich).
    public static func plan(_ requests: [Request], pattern: FilenamePattern) -> Plan {
        var items: [Item] = []
        // Zielnamen je Ordner, schon vergeben durch frühere Einträge des Plans.
        var claimed: [URL: [String: String]] = [:]   // Ordner → Vergleichsname → Quelle
        // Sidecars, die ein früherer Eintrag schon mitnimmt: Quelle → Zielname.
        // Ein RAW+JPEG-Paar teilt sich eine Sidecar; gleiche Zielnamen sind
        // dann in Ordnung, verschiedene ein Konflikt.
        var sidecarMoves: [String: String] = [:]
        var caseSensitivity: [URL: Bool] = [:]

        for request in requests {
            let source = request.url
            let directory = source.deletingLastPathComponent()
            let caseSensitive: Bool
            if let known = caseSensitivity[directory] {
                caseSensitive = known
            } else {
                caseSensitive = isCaseSensitive(directory: directory)
                caseSensitivity[directory] = caseSensitive
            }
            let target = pattern.renderFileName(fields: request.fields, extension: source.pathExtension)
            var item = Item(source: source.path, target: target, status: .rename, reason: nil)

            // Vergleichsname: auf Datenträgern ohne Unterscheidung der
            // Schreibweise klein geschrieben, damit "a" und "A" kollidieren.
            func comparable(_ name: String) -> String {
                caseSensitive ? name : name.lowercased()
            }

            if target.isEmpty {
                item.status = .conflict
                item.reason = "Pattern yields an empty name (all fields empty)"
            } else if target == source.lastPathComponent {
                item.status = .unchanged
            } else if let other = claimed[directory]?[comparable(target)] {
                item.status = .conflict
                item.reason = "Same target name as \(other)"
            } else if comparable(target) != comparable(source.lastPathComponent),
                      FileManager.default.fileExists(atPath: item.targetURL.path) {
                // Ein anderer Eintrag des Plans könnte diese Datei gerade
                // freigeben (A→B, B→C). Das wäre reihenfolgeabhängig und wird
                // deshalb bewusst als Konflikt gemeldet, nicht aufgelöst.
                item.status = .conflict
                item.reason = "A file with this name already exists"
            }

            // Namensgebundene Sidecar (XMP/LRC/NFO): gleicher Stamm wie das
            // neue Ziel, sonst fände die Mediendatei ihre Werte nicht mehr.
            if item.status == .rename {
                for sidecar in companionSidecars(of: source) {
                    let sidecarTarget = item.targetURL.deletingPathExtension()
                        .appendingPathExtension(sidecar.pathExtension).lastPathComponent
                    if let earlier = sidecarMoves[sidecar.path] {
                        // Dieselbe Sidecar nimmt schon ein früherer Eintrag mit.
                        if comparable(earlier) != comparable(sidecarTarget) {
                            item.status = .conflict
                            item.reason = "Sidecar \(sidecar.lastPathComponent) is shared and would get two different names"
                        }
                    } else if let other = claimed[directory]?[comparable(sidecarTarget)] {
                        item.status = .conflict
                        item.reason = "Sidecar target \(sidecarTarget) has the same name as \(other)"
                    } else if comparable(sidecarTarget) != comparable(sidecar.lastPathComponent),
                              FileManager.default.fileExists(
                                atPath: directory.appendingPathComponent(sidecarTarget).path) {
                        item.status = .conflict
                        item.reason = "A file named \(sidecarTarget) already exists (sidecar target)"
                    } else {
                        if item.sidecarSource == nil {
                            item.sidecarSource = sidecar.path
                            item.sidecarTarget = sidecarTarget
                        } else {
                            item.additionalSidecars = (item.additionalSidecars ?? [])
                                + [SidecarMove(source: sidecar.path, target: sidecarTarget)]
                        }
                    }
                }
            }

            // Auch unveränderte Namen belegen ihren Platz: Ein zweiter Eintrag
            // darf nicht auf den Namen einer Datei umbenannt werden, die
            // unverändert bleibt.
            if item.status != .conflict {
                claimed[directory, default: [:]][comparable(target)] = source.lastPathComponent
                for move in item.sidecarMoves {
                    claimed[directory, default: [:]][comparable(move.target)] = move.source
                    sidecarMoves[move.source] = move.target
                }
            }
            items.append(item)
        }
        return Plan(items: items)
    }

    /// Namensgebundene Sidecars. Sprachsuffixe wie `film.de.srt` bleiben
    /// ausgenommen, weil ihre Zuordnung nicht eindeutig ist.
    static func companionSidecars(of source: URL) -> [URL] {
        sidecarCandidates(of: source).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Auch nach einem fehlgeschlagenen Umzug muss eine inzwischen fehlende
    /// Sidecar als Abhängigkeit des Plans erkennbar bleiben.
    private static func sidecarCandidates(of source: URL) -> [URL] {
        let ext = source.pathExtension.lowercased()
        if MediaFormats.image.contains(ext) {
            return MediaFormats.isXMPSidecar(source) ? [] : [MediaFormats.sidecarURL(for: source)]
        }
        var candidates: [URL] = []
        if MediaFormats.nfoVideo.contains(ext) {
            candidates.append(source.deletingPathExtension().appendingPathExtension(SidecarTool.nfoExtension))
        }
        if MediaFormats.audio.contains(ext) { candidates.append(LRC.sidecarURL(for: source)) }
        return candidates
    }

    /// Führt die Umbenennungen des Plans aus — nur die Einträge mit Status
    /// `rename`. Vorbedingung: `plan.hasConflicts == false`; ein Plan mit
    /// Konflikten wird komplett abgelehnt, damit nie ein Teil eines Albums
    /// umbenannt ist und der Rest nicht.
    ///
    /// Jede Datei wird direkt vor ihrem `moveItem` noch einmal geprüft
    /// (Quelle vorhanden, Ziel frei). `moveItem` selbst überschreibt nie.
    /// Schlägt ein Eintrag fehl, laufen die übrigen weiter; das Ergebnis
    /// nennt jeden Eintrag einzeln.
    ///
    /// Nach jeder gelungenen Umbenennung zeigen die Einträge im Sicherungs-
    /// `journal` auf den neuen Pfad — sonst fände „Letzte Änderung
    /// rückgängig“ die Versionen von vor der Umbenennung nicht mehr.
    public static func apply(_ plan: Plan, journal: BackupJournal = .standard) throws -> [Outcome] {
        try apply(plan, journal: journal) { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    /// Austauschbarer Dateiumzug für deterministische Fehlerprüfungen:
    /// Tests bewegen echte Dateien und können genau einen Umzug ablehnen.
    static func apply(_ plan: Plan, journal: BackupJournal,
                      moveItem: (URL, URL) throws -> Void) throws -> [Outcome] {
        guard !plan.hasConflicts else { throw RenameError.planHasConflicts }
        let renames = plan.renames
        // Nur der erste Eintrag bewegt eine geteilte Sidecar. Weitere
        // Einträge dürfen erst folgen, wenn dieser Umzug gelungen ist.
        var owners: [String: String] = [:]
        for item in renames {
            for move in item.sidecarMoves where owners[move.source] == nil {
                owners[move.source] = item.source
            }
        }
        var movedSidecars: [String: String] = [:]
        var outcomes: [Outcome] = []
        for item in renames {
            let sourceURL = item.sourceURL
            let targetURL = item.targetURL
            var outcome = Outcome(source: item.source, target: targetURL.path, error: nil)
            do {
                var sharedTargets: [String] = []
                for candidate in sidecarCandidates(of: sourceURL) {
                    if let owner = owners[candidate.path], owner != item.source {
                        guard let target = movedSidecars[candidate.path] else {
                            throw RenameError.sharedSidecarNotRenamed(path: candidate.path)
                        }
                        sharedTargets.append(target)
                    }
                }
                let moves = [(sourceURL, targetURL)] + item.sidecarMoves.map { ($0.sourceURL, $0.targetURL) }
                for (source, target) in moves { try requireMovable(from: source, to: target) }
                var completed: [(URL, URL)] = []
                do {
                    for (source, target) in moves {
                        try moveItem(source, target)
                        completed.append((source, target))
                    }
                } catch {
                    // In umgekehrter Reihenfolge zurück; auch nach einem
                    // Rückwegfehler die übrigen Dateien wiederherstellen.
                    var rollbackErrors: [String] = []
                    for (source, target) in completed.reversed() {
                        do { try moveItem(target, source) }
                        catch { rollbackErrors.append("\(target.path): \(error.localizedDescription)") }
                    }
                    if !rollbackErrors.isEmpty {
                        throw RenameError.sidecarRollbackFailed(
                            file: targetURL.path,
                            sidecar: item.sidecarMoves.map(\.source).joined(separator: ", "),
                            reason: "\(error.localizedDescription); moving back failed: \(rollbackErrors.joined(separator: "; "))")
                    }
                    throw error
                }
                for move in item.sidecarMoves { movedSidecars[move.source] = move.targetURL.path }
                let targets = item.sidecarMoves.map { $0.targetURL.path } + sharedTargets
                outcome.sidecarTarget = targets.first
                outcome.additionalSidecarTargets = targets.count > 1 ? Array(targets.dropFirst()) : nil
                // Jeden Journalpfad nachziehen, auch wenn ein anderer scheitert.
                var warnings: [String] = []
                for (source, target) in moves {
                    do { try journal.relocate(from: source, to: target) }
                    catch { warnings.append(error.localizedDescription) }
                }
                if !warnings.isEmpty {
                    outcome.warning = "renamed, but the backup history could not be updated: "
                        + warnings.joined(separator: "; ")
                }
            } catch {
                outcome.error = error.localizedDescription
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// Quelle vorhanden, Ziel frei (oder dieselbe Datei in anderer Schreibweise).
    private static func requireMovable(from sourceURL: URL, to targetURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw RenameError.sourceMissing(path: sourceURL.path)
        }
        let sameFile = FileStamp.current(of: sourceURL).flatMap { sourceStamp in
            FileStamp.current(of: targetURL).map { sourceStamp.hasSameFileIdentity(as: $0) }
        } ?? false
        if !sameFile, fm.fileExists(atPath: targetURL.path) {
            throw RenameError.targetExists(path: targetURL.path)
        }
    }

    public enum RenameError: Error, LocalizedError, Equatable, Sendable {
        case planHasConflicts
        case sourceMissing(path: String)
        case sharedSidecarNotRenamed(path: String)
        case targetExists(path: String)
        /// Mindestens ein Rückweg ist gescheitert. `reason` nennt die
        /// tatsächlich verbliebenen Zielpfade; andere Dateien können bereits zurück sein.
        case sidecarRollbackFailed(file: String, sidecar: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .planHasConflicts:
                return "The rename plan has conflicts; nothing was renamed"
            case .sharedSidecarNotRenamed(let path):
                return "Shared sidecar was not renamed; dependent file stays unchanged: \(path)"
            case .sourceMissing(let path):
                return "File disappeared before renaming: \(path)"
            case .targetExists(let path):
                return "A file with this name appeared in the meantime: \(path)"
            case .sidecarRollbackFailed(let file, let sidecar, let reason):
                return "Could not fully restore the rename group for \(file) and sidecars \(sidecar): \(reason)"
            }
        }
    }
}
