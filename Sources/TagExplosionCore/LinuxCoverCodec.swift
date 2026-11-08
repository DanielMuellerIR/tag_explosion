#if os(Linux)
import Foundation

/// ImageMagick bleibt ein getrenntes Programm. Prüfregeln, Metadatenstripper
/// und alle Dateischreibwege werden weiterhin vom gemeinsamen Core ausgeführt.
enum LinuxCoverCodec {
    static var executable: String? {
        try? ExternalToolRunner.locateTool(candidates: ["magick", "convert", "/usr/bin/convert"], name: "ImageMagick")
    }

    static func convert(_ data: Data, maxPixelSize: Int?, format: CoverTools.OutputFormat, quality: Double) throws -> Data {
        guard let executable else { throw CoverToolError.conversionUnavailable }
        guard data.count <= 64 * 1024 * 1024,
              let size = ImagePixelSize.read(from: data), size.width > 0, size.height > 0,
              size.width <= 32768, size.height <= 32768,
              Int64(size.width) * Int64(size.height) <= 100_000_000,
              maxPixelSize.map({ $0 > 0 && $0 <= 32768 }) ?? true,
              quality.isFinite else { throw CoverToolError.unsupportedImage }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tagx-cover-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try data.write(to: source)
        var arguments = ["-limit", "memory", "256MiB", "-limit", "map", "256MiB", "-limit", "disk", "256MiB",
                         "-limit", "thread", "2", source.path + "[0]", "-auto-orient"]
        if let maxPixelSize { arguments += ["-thumbnail", "\(maxPixelSize)x\(maxPixelSize)>"] }
        if format == .jpeg { arguments += ["-background", "white", "-alpha", "remove", "-alpha", "off"] }
        arguments += ["-colorspace", "sRGB", "-strip", "-quality", String(Int(min(max(quality, 0), 1) * 100)), format.rawValue + ":-"]
        var environment = ExternalToolRunner.utf8Environment()
        environment["MAGICK_TEMPORARY_PATH"] = directory.path
        return try ExternalToolRunner.run(executable, arguments, processTimeout: 30,
                                          outputLimit: 64 * 1024 * 1024, environment: environment)
    }
}
#endif
