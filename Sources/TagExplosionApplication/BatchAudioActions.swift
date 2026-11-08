import Foundation
import TagExplosionCore

@MainActor
public enum BatchAudioActions {
    public static func copyValues(from source: String, to target: String, entries: [FileEntry]) {
        for entry in entries {
            let values = entry.properties.filter { $0.key == source }.map(\.value)
            guard !values.isEmpty else { continue }
            entry.properties.removeAll { $0.key == target }
            entry.properties.append(contentsOf: values.map { TagProperty(key: target, value: $0) })
        }
    }
    public static func renumber(_ entries: [FileEntry]) {
        for (index, entry) in entries.enumerated() { entry.setSingleValue("TRACKNUMBER", "\(index + 1)/\(entries.count)") }
    }

    public static func titleFromFilename(_ entry: FileEntry) -> String {
        var name = entry.url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"^\d+\s*[-_.–]\s*"#, options: .regularExpression) {
            name = String(name[range.upperBound...])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
