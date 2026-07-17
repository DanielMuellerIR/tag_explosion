// swift-tools-version:6.0
// SwiftUI-App von Tag Explosion — eigenes Paket, damit das Root-Paket
// (Core + CLI) ohne SwiftUI auf Linux baubar bleibt.
import PackageDescription

let package = Package(
    name: "TagExplosionApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "TagExplosionApp",
            dependencies: [
                .product(name: "TagExplosionCore", package: "tag_explosion"),
            ]
        ),
    ]
)
