// Cover-Anzeige mit Drag&Drop, Austausch, Export und Entfernen.
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct CoverWell: View {
    @Bindable var entry: FileEntry
    @State private var isTargeted = false

    private var artwork: Artwork? { entry.artworks.first }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
                if let artwork, let image = NSImage(data: artwork.data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                        Text("Cover hierher\nziehen")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .frame(width: 180, height: 180)
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
            .contextMenu {
                Button("Bild auswählen …") { pickImage() }
                if artwork != nil {
                    Button("Exportieren …") { exportImage() }
                    Button("Cover entfernen", role: .destructive) {
                        entry.artworks = []
                    }
                }
            }
            .onTapGesture { pickImage() }

            if let artwork {
                Text("\(artwork.resolvedMimeType.replacingOccurrences(of: "image/", with: "").uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(artwork.data.count), countStyle: .file))\(entry.artworks.count > 1 ? " · " + String(localized: "+\(entry.artworks.count - 1) weitere") : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Ersetzt das Cover (weitere eingebettete Bilder bleiben erhalten).
    private func setCover(data: Data) {
        guard Artwork.sniffMimeType(from: data) != nil else { return }
        let newArtwork = Artwork(data: data, pictureType: "Front Cover")
        if entry.artworks.isEmpty {
            entry.artworks = [newArtwork]
        } else {
            entry.artworks[0] = newArtwork
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        CoverDrop.load(providers) { setCover(data: $0) }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Coverbild auswählen")
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            setCover(data: data)
        }
    }

    private func exportImage() {
        guard let artwork else { return }
        let panel = NSSavePanel()
        let ext = CoverExport.fileExtension(for: artwork.resolvedMimeType)
        panel.nameFieldStringValue = entry.url.deletingPathExtension()
            .lastPathComponent + "-cover." + ext
        if panel.runModal() == .OK, let url = panel.url {
            try? artwork.data.write(to: url)
        }
    }
}

/// Dateiendung für unveränderte Coverdaten. Unbekannte Daten dürfen nicht
/// als JPEG beschriftet werden; die neutrale Endung hält den Inhalt ehrlich.
enum CoverExport {
    static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/bmp": return "bmp"
        default: return "bin"
        }
    }
}

/// Gemeinsames Drop-Handling für Cover: bevorzugt als Datei-URL (aus dem
/// Finder), sonst als rohe Bilddaten (z.B. aus Safari); validiert per Magic
/// Bytes und liefert auf dem Main-Thread. `acceptedMimeTypes` schränkt die
/// Formate ein (nil = jedes erkannte Bildformat).
enum CoverDrop {
    static func load(_ providers: [NSItemProvider],
                     acceptedMimeTypes: Set<String>? = nil,
                     accept: @escaping @MainActor @Sendable (Data) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        Loader(providers: providers, acceptedMimeTypes: acceptedMimeTypes,
               accept: accept).start()
        return true
    }

    /// Prüft Provider nacheinander und stoppt beim ersten gültigen Bild. Das
    /// erhält die Drop-Reihenfolge und verhindert, dass parallel eintreffende
    /// Callbacks dasselbe Cover mehrfach oder in Zufallsreihenfolge ersetzen.
    private final class Loader: @unchecked Sendable {
        private let providers: [NSItemProvider]
        private let acceptedMimeTypes: Set<String>?
        private let accept: @MainActor @Sendable (Data) -> Void

        init(providers: [NSItemProvider], acceptedMimeTypes: Set<String>?,
             accept: @escaping @MainActor @Sendable (Data) -> Void) {
            self.providers = providers
            self.acceptedMimeTypes = acceptedMimeTypes
            self.accept = accept
        }

        func start() {
            loadProvider(at: 0)
        }

        private func loadProvider(at index: Int) {
            guard providers.indices.contains(index) else { return }
            let provider = providers[index]
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { [self] url, _ in
                    if let url, let data = try? Data(contentsOf: url), deliver(data) {
                        return
                    }
                    // Manche Provider bieten neben einer unbrauchbaren
                    // Datei-URL noch eine konvertierte Bildrepräsentation an.
                    loadImageData(at: index)
                }
            } else {
                loadImageData(at: index)
            }
        }

        private func loadImageData(at index: Int) {
            guard providers.indices.contains(index) else { return }
            let provider = providers[index]
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { [self] data, _ in
                if let data, deliver(data) { return }
                loadProvider(at: index + 1)
            }
        }

        private func deliver(_ data: Data) -> Bool {
            guard let mime = Artwork.sniffMimeType(from: data),
                  acceptedMimeTypes?.contains(mime) ?? true else { return false }
            Task { @MainActor [accept] in accept(data) }
            return true
        }
    }
}
