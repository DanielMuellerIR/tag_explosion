import AppKit
import SwiftUI

extension MetadataPreview {
    @MainActor
    public func makeView() -> NSView {
        NSHostingView(rootView: MetadataPreviewView(preview: self))
    }
}

private struct MetadataPreviewView: View {
    let preview: MetadataPreview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    if let cover = preview.cover, let image = NSImage(data: cover.data) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 120, height: 160)
                            .accessibilityLabel("Cover")
                    }
                    Text(preview.fileName).font(.title2).bold().textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVStack(spacing: 0) {
                    ForEach(preview.rows.indices, id: \.self) { index in
                        let row = preview.rows[index]
                        HStack(alignment: .top, spacing: 16) {
                            Text(row.0).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).frame(width: 135, alignment: .leading)
                            Text(row.1).font(.system(size: 14)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
                Text("Tag Explosion").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 420, minHeight: 300)
    }
}
