// Startangebot: fehlende externe Brew-Werkzeuge (mediainfo, exiftool) erkennen
// und auf Wunsch über Homebrew installieren. Muster wie in md-clip und
// Poor Man's Text: Das Angebot erscheint bei jedem Start, solange etwas fehlt,
// bis der Nutzer „Nicht mehr fragen" wählt.
import SwiftUI
import TagExplosionCore

/// Entscheidungslogik und Homebrew-Aufruf, getrennt von SwiftUI testbar.
enum BrewToolInstaller {
    /// UserDefaults-Key für die dauerhafte Ablehnung.
    static let declinedDefaultsKey = "BrewToolInstallDeclined"

    /// Übliche Homebrew-Orte: Apple Silicon zuerst, dann Intel.
    static let homebrewCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
        URL(fileURLWithPath: "/usr/local/bin/brew"),
    ]

    /// Ohne Homebrew verweist der Dialog hierhin; ist Homebrew erst da, kann
    /// die App die Werkzeuge beim nächsten Start selbst installieren.
    static let homebrewHelpURL = URL(string: "https://brew.sh")!

    /// Fehlende brew-Formeln in Anzeige-Reihenfolge; Formelname == Werkzeugname.
    /// Calibre bleibt bewusst außen vor: optionales Extra (mobi/azw3/fb2) und
    /// ein Cask mit kompletter GUI-App statt einer kleinen Formel.
    static func missingTools() -> [String] {
        var missing: [String] = []
        if (try? MediaInfoReader.locateExecutable()) == nil { missing.append("mediainfo") }
        if (try? ExifTool.locateExecutable()) == nil { missing.append("exiftool") }
        return missing
    }

    static func resolveHomebrew(
        candidates: [URL] = homebrewCandidates,
        fileManager: FileManager = .default
    ) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Was die App beim Start anbieten kann.
    enum Offer: Equatable {
        /// Homebrew ist vorhanden: automatische Installation anbieten.
        case homebrewInstall(brewExecutable: URL, missingTools: [String])
        /// Kein Homebrew: nur den Weg dorthin zeigen.
        case manualGuidance(missingTools: [String])
    }

    /// `nil` heißt: nichts anzeigen — alles da oder dauerhaft abgelehnt.
    static func offer(
        missingTools: [String],
        installDeclined: Bool,
        brewExecutable: URL?
    ) -> Offer? {
        guard !missingTools.isEmpty, !installDeclined else { return nil }
        if let brewExecutable {
            return .homebrewInstall(brewExecutable: brewExecutable, missingTools: missingTools)
        }
        return .manualGuidance(missingTools: missingTools)
    }

    static func install(brewExecutable: URL, formulae: [String]) throws {
        try install(brewExecutable: brewExecutable, formulae: formulae) {
            missingTools().isEmpty
        }
    }

    static func install(
        brewExecutable: URL,
        formulae: [String],
        verifyInstallation: () -> Bool
    ) throws {
        let process = Process()
        process.executableURL = brewExecutable
        process.arguments = ["install"] + formulae

        let standardError = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw InstallError.processFailed(error.localizedDescription)
        }
        // Erst die Fehler-Pipe bis EOF leeren, DANN auf das Prozessende warten:
        // Ein Kind mit mehr Ausgabe, als der Pipe-Puffer fasst, würde sonst
        // auf einen Leser warten, während wir auf sein Ende warten — Deadlock.
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.processFailed(message.isEmpty ? "Exit-Status \(process.terminationStatus)" : message)
        }
        guard verifyInstallation() else {
            throw InstallError.verificationFailed
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case processFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .processFailed(let message):
                String(localized: "Homebrew konnte die Werkzeuge nicht installieren: \(message)")
            case .verificationFailed:
                String(localized: "Homebrew ist fertig, aber die Werkzeuge sind weiterhin nicht auffindbar.")
            }
        }
    }
}

/// Hängt Start-Dialog, Fortschrittsanzeige und Ergebnis-Meldungen als einen
/// einzigen Modifier an die ContentView.
struct BrewToolInstallOffer: ViewModifier {
    @AppStorage(BrewToolInstaller.declinedDefaultsKey) private var installDeclined = false
    @State private var offer: BrewToolInstaller.Offer?
    @State private var installingTools: [String] = []
    @State private var installedTools: [String] = []
    @State private var installError: String?

    func body(content: Content) -> some View {
        content
            .task { prepareOffer() }
            .confirmationDialog(
                offerTitle,
                isPresented: .init(
                    get: { offer != nil },
                    set: { if !$0 { offer = nil } }
                ),
                titleVisibility: .visible
            ) {
                if case .homebrewInstall(let brewExecutable, let missing) = offer {
                    Button("Mit Homebrew installieren") {
                        install(brewExecutable: brewExecutable, formulae: missing)
                    }
                } else {
                    Button("brew.sh öffnen") {
                        NSWorkspace.shared.open(BrewToolInstaller.homebrewHelpURL)
                    }
                }
                Button("Später", role: .cancel) {
                    offer = nil
                }
                Button("Nicht mehr fragen") {
                    installDeclined = true
                    offer = nil
                }
            } message: {
                if case .homebrewInstall(_, let missing) = offer {
                    Text("Tag Explosion nutzt \(toolList(missing)) für technische Mediendaten sowie Bild- und PDF-Metadaten. Jetzt über Homebrew installieren? Das kann einige Minuten dauern.")
                } else if case .manualGuidance(let missing) = offer {
                    Text("Tag Explosion nutzt \(toolList(missing)), aber weder die Werkzeuge noch Homebrew wurden gefunden. Bitte zuerst Homebrew installieren — danach kann die App die Werkzeuge selbst einrichten.")
                }
            }
            .overlay(alignment: .bottom) {
                if !installingTools.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installiere \(toolList(installingTools)) …")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                }
            }
            .alert("Werkzeuge installiert", isPresented: .init(
                get: { !installedTools.isEmpty },
                set: { if !$0 { installedTools = [] } }
            )) {
                Button("OK") { installedTools = [] }
            } message: {
                Text("Jetzt verfügbar: \(toolList(installedTools)).")
            }
            .alert("Installation fehlgeschlagen", isPresented: .init(
                get: { installError != nil },
                set: { if !$0 { installError = nil } }
            )) {
                Button("OK", role: .cancel) { installError = nil }
            } message: {
                Text(installError ?? "")
            }
    }

    private var offerTitle: Text {
        if case .manualGuidance = offer {
            return Text("Zusatzwerkzeuge fehlen")
        }
        return Text("Zusatzwerkzeuge installieren?")
    }

    /// Sprachrichtige Aufzählung („mediainfo und exiftool").
    private func toolList(_ tools: [String]) -> String {
        tools.formatted(.list(type: .and))
    }

    private func prepareOffer() {
        offer = BrewToolInstaller.offer(
            missingTools: BrewToolInstaller.missingTools(),
            installDeclined: installDeclined,
            brewExecutable: BrewToolInstaller.resolveHomebrew()
        )
    }

    private func install(brewExecutable: URL, formulae: [String]) {
        offer = nil
        installingTools = formulae

        // Der Homebrew-Aufruf läuft außerhalb des Main Actors; `brew install`
        // kann mehrere Minuten dauern und darf das Fenster nicht blockieren.
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BrewToolInstaller.install(brewExecutable: brewExecutable, formulae: formulae)
                }.value
                installedTools = formulae
            } catch {
                installError = error.localizedDescription
            }
            installingTools = []
        }
    }
}
