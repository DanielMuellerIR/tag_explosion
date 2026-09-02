// tagx layers show/strip — Tag-Schichten (ID3v1, ID3v2, APEv2, RIFF INFO,
// Vorbis) einzeln anzeigen und entfernen. MP3 trägt oft ID3v1 UND ID3v2;
// alte Reste (ID3v1 mit gekürzten Titeln, APE aus Fremdprogrammen) lassen
// sich hier gezielt loswerden, ohne die anderen Schichten anzufassen.
import ArgumentParser
import Foundation
import TagExplosionCore

struct Layers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or remove tag layers (ID3v1, ID3v2, APE, RIFF INFO, Vorbis).",
        subcommands: [LayersShow.self, LayersStrip.self],
        defaultSubcommand: LayersShow.self
    )
}

/// JSON-Form von `layers show`.
struct LayerReport: Codable {
    var file: String
    /// Leer bei Formaten ohne Schichtenmodell (MP4, Ogg, Matroska …).
    var layers: [TagLayer]
}

struct LayersShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "List the tag layers of a file with version and field names.")

    @Argument(help: "Media file") var file: String
    @Flag(name: .long, help: "Output as JSON ({file, layers: [{kind, version, present, strippable, fields}]})")
    var json = false

    func run() throws {
        let url = try resolveFile(file)
        let layers = try TagFile.read(at: url).layers
        if json {
            try printJSON(LayerReport(file: url.path, layers: layers))
            return
        }
        if layers.isEmpty {
            FileHandle.standardError.write(
                Data("Note: \(url.lastPathComponent) — this format has no tag layers\n".utf8))
            return
        }
        // Eine Zeile je Schicht: Kennung, Name, Status, Felder.
        for layer in layers {
            let status = layer.present ? "present" : "absent"
            let fields = layer.fields.isEmpty ? "" : " · " + layer.fields.joined(separator: ", ")
            print("\(layer.kind.rawValue): \(layer.displayName) · \(status)\(fields)")
        }
    }
}

struct LayersStrip: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strip",
        abstract: "Remove one or more tag layers (the other layers stay untouched).")

    @Argument(help: "Media file") var file: String
    @Option(name: .long, parsing: .upToNextOption,
            help: "Layer(s) to remove: id3v1, id3v2, ape, info, vorbis")
    var layer: [String]
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        guard !layer.isEmpty else { throw ValidationError("Provide at least one --layer.") }
        var kinds = Swift.Set<TagLayerKind>()
        for name in layer {
            guard let kind = TagLayerKind(rawValue: name.lowercased()) else {
                throw ValidationError("Unknown layer '\(name)' (expected id3v1, id3v2, ape, info, vorbis)")
            }
            kinds.insert(kind)
        }
        let url = try resolveFile(file)
        // Inhalt und Stempel gehören zusammen (siehe `tagx set`).
        let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
        // Fehlende oder nicht entfernbare Schichten ablehnen, bevor eine
        // Sicherung entsteht; die Fehlertexte kommen aus dem Core.
        for kind in kinds {
            guard let known = snapshot.value.layers.first(where: { $0.kind == kind }),
                  known.present, known.strippable
            else {
                throw ValidationError(
                    TagError.layerUnsupported(path: url.path, layer: kind.rawValue).localizedDescription)
            }
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url)
        try TagFile.stripLayers(kinds, from: url, expecting: snapshot.stamp)
        let names = kinds.map(\.rawValue).sorted().joined(separator: ", ")
        print("OK \(url.lastPathComponent): layer(s) removed: \(names)")
    }
}
