// Tab 2: vollständige technische Details via mediainfo — gruppiert,
// durchsuchbar, kopierbar.
import SwiftUI
import TagExplosionCore

struct MediaInfoTab: View {
    let url: URL

    @State private var report: MediaInfoReport?
    @State private var errorText: String?
    @State private var filter = ""

    var body: some View {
        Group {
            if let report {
                reportView(report)
            } else if let errorText {
                ContentUnavailableView(
                    "MediaInfo nicht verfügbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else {
                ProgressView("Analysiere …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            report = nil
            errorText = nil
            let target = url
            do {
                report = try await Task.detached(priority: .userInitiated) {
                    try MediaInfoReader.read(url: target)
                }.value
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func reportView(_ report: MediaInfoReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filtern …", text: $filter)
                    .textFieldStyle(.plain)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                } label: {
                    Label("Report kopieren", systemImage: "doc.on.doc")
                }
                .help("Vollständigen mediainfo-Report in die Zwischenablage kopieren")
            }
            .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(report.tracks.enumerated()), id: \.offset) { _, track in
                        let fields = filteredFields(track)
                        if !fields.isEmpty {
                            GroupBox(track.type) {
                                Grid(alignment: .leadingFirstTextBaseline,
                                     horizontalSpacing: 16, verticalSpacing: 4) {
                                    ForEach(fields, id: \.self) { field in
                                        GridRow {
                                            Text(field.key)
                                                .foregroundStyle(.secondary)
                                                .gridColumnAlignment(.trailing)
                                            Text(field.value)
                                                .font(.body.monospaced())
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(6)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func filteredFields(_ track: MediaInfoTrack) -> [TagProperty] {
        guard !filter.isEmpty else { return track.fields }
        return track.fields.filter {
            $0.key.localizedCaseInsensitiveContains(filter)
                || $0.value.localizedCaseInsensitiveContains(filter)
        }
    }
}
