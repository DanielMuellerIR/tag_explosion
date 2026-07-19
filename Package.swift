// swift-tools-version:6.0
// Tag Explosion — Medien-Tag-Anzeige und -Editor.
// Aufbau: CTagLib (System-TagLib via pkg-config) → CTagShim (eigener C++-Shim
// mit C-Schnittstelle) → TagExplosionCore (portables Swift) → tagx (CLI).
// Die macOS-GUI liegt als eigenes Executable-Target in App/.
import PackageDescription

let package = Package(
    name: "TagExplosion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TagExplosionCore", targets: ["TagExplosionCore"]),
        .executable(name: "tagx", targets: ["tagx"]),
    ],
    dependencies: [
        // Apache-2.0, MIT-kompatibel
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // MIT — ZIP-Container-Zugriff für EPUB (läuft auch unter Linux)
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        // System-TagLib (Homebrew: `brew install taglib`, Debian/Ubuntu: libtag-dev).
        // Liefert Include-/Linker-Flags über pkg-config an abhängige Targets.
        .systemLibrary(
            name: "CTagLib",
            pkgConfig: "taglib_c",
            providers: [.brew(["taglib"]), .apt(["libtag-dev", "libtag1-dev"])]
        ),
        // Eigener C++-Shim (MIT): einziger Berührungspunkt mit der TagLib-C++-API.
        .target(
            name: "CTagShim",
            dependencies: ["CTagLib"]
        ),
        // Portabler Kern: Datenmodell, Tag-IO, MediaInfo-Wrapper. Kein AppKit/SwiftUI.
        .target(
            name: "TagExplosionCore",
            dependencies: [
                "CTagShim",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // CLI für Headless-Betrieb, Tests und Batch-Skripting.
        .executableTarget(
            name: "tagx",
            dependencies: [
                "TagExplosionCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TagExplosionCoreTests",
            dependencies: ["TagExplosionCore"],
            // Fixture-Generator liegt daneben; Tests rufen ihn bei Bedarf auf.
            exclude: ["Fixtures"]
        ),
        // Echte CLI-Regressionen prüfen ArgumentParser-Fehler und Exit-Codes.
        .testTarget(
            name: "TagxTests",
            dependencies: ["TagExplosionCore"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
