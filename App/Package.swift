// swift-tools-version:6.0
// SwiftUI-App von Tag Explosion — eigenes Paket, damit das Root-Paket
// (Core + CLI) ohne SwiftUI auf Linux baubar bleibt.
import PackageDescription

let package = Package(
    name: "TagExplosionApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        // Auto-Updates. Exakt gepinnt, nicht per Range: Ein Updater läuft mit
        // Schreibrechten im Installationspfad — Versionssprünge werden bewusst
        // geprüft übernommen, nie still.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "TagExplosionApp",
            dependencies: [
                .product(name: "TagExplosionCore", package: "tag_explosion"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // build.sh legt Sparkle.framework in Contents/Frameworks ab.
                // SwiftPM ergänzt für Binär-Targets nur @loader_path (neben dem
                // Executable); den Bundle-rpath müssen wir daher selbst setzen.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
            ]
        ),
    ]
)
