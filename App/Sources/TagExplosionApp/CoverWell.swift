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
        guard let provider = providers.first else { return false }
        // Bevorzugt als Datei-URL (aus Finder), sonst als Bilddaten (z.B. aus Safari)
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                DispatchQueue.main.async { setCover(data: data) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            DispatchQueue.main.async { setCover(data: data) }
        }
        return true
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
        let ext: String
        switch artwork.resolvedMimeType {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        panel.nameFieldStringValue = entry.url.deletingPathExtension()
            .lastPathComponent + "-cover." + ext
        if panel.runModal() == .OK, let url = panel.url {
            try? artwork.data.write(to: url)
        }
    }
}
