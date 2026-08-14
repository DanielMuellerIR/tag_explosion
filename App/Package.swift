// swift-tools-version:6.0
// SwiftUI-App von Tag Explosion — eigenes Paket, damit das Root-Paket
// (Core + CLI) ohne SwiftUI auf Linux baubar bleibt.
import PackageDescription

let package = Package(
    name: "TagExplosionApp",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Der explizite Name entkoppelt die Paketidentitaet vom Namen des
        // Checkouts/Worktrees (z.B. einem temporaeren Review-Verzeichnis).
        .package(name: "TagExplosion", path: ".."),
        // Auto-Updates. Exakt gepinnt, nicht per Range: Ein Updater läuft mit
        // Schreibrechten im Installationspfad — Versionssprünge werden bewusst
        // geprüft übernommen, nie still.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "TagExplosionApp",
            dependencies: [
                .product(name: "TagExplosionCore", package: "TagExplosion"),
                .product(name: "EInvoiceCore", package: "TagExplosion"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                // build.sh legt Sparkle.framework in Contents/Frameworks ab.
                // SwiftPM ergänzt für Binär-Targets nur @loader_path (neben dem
                // Executable); den Bundle-rpath müssen wir daher selbst setzen.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
            ]
        ),
        // Der Save-Zustand wird ohne SwiftUI-Fenster getestet. So bleiben
        // Nebenläufigkeitsfehler auch in der macOS-CI sichtbar.
        .testTarget(
            name: "TagExplosionAppTests",
            dependencies: ["TagExplosionApp"]
        ),
    ]
)
