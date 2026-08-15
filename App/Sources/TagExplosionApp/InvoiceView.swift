// E-Rechnungs-Ansicht: Profilkopf + alle Felder mit EN-16931-Bezeichnungen
// (BT-/BG-Nummern). Reine Anzeige, filterbar, kopierbar. Wird zweifach
// genutzt: als Editor-Ersatz für XML-Rechnungen und als Tab im
// E-Book-Editor, wenn ein PDF eine eingebettete Rechnung trägt.
import EInvoiceCore
import SwiftUI
import TagExplosionCore

/// Detailansicht für einen .invoice-Eintrag (XML-Rechnung).
struct InvoiceView: View {
    @Bindable var entry: FileEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.url.lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(entry.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)

            if let document = entry.invoiceDocument {
                InvoiceContentView(document: document)
            } else {
                ContentUnavailableView(
                    "Keine E-Rechnung erkannt",
                    systemImage: "doc.questionmark",
                    description: Text("Die Datei enthält keine lesbare E-Rechnung.")
                )
            }
        }
        .background(.background)
    }
}

/// Gemeinsamer Anzeigekern: Profilkopf, Filter, Feldliste. Der E-Book-Editor
/// nutzt ihn für sein Rechnungs-Tab mit dem dort bereits gelesenen Dokument —
/// das PDF wird dafür nicht ein zweites Mal extrahiert und geparst.
struct InvoiceContentView: View {
    let document: EInvoiceDocument

    @State private var filter = ""
    /// Nur Felder mit EN-16931-Zuordnung zeigen (blendet Struktur-Rauschen aus).
    @State private var termsOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            fieldList
        }
    }

    // MARK: - Profilkopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("\(document.profile.standard) · \(document.profile.profile)")
                    .font(.headline)
                Text(document.syntax.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
                headerRow("Spezifikation (BT-24)", document.profile.guidelineID)
                if let process = document.profile.businessProcessID {
                    headerRow("Geschäftsprozess (BT-23)", process)
                }
                if case .pdfEmbedded(let fileName) = document.source {
                    headerRow("Eingebettet als", fileName)
                }
                if let declaration = document.pdfDeclaration {
                    headerRow("PDF-Deklaration (XMP)", [
                        declaration.documentType,
                        declaration.version.map { "Version \($0)" },
                        declaration.conformanceLevel,
                    ].compactMap(\.self).joined(separator: " · "))
                }
                if let summary = summaryLine {
                    headerRow("Eckdaten", summary)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// `label` ist ein LocalizedStringKey, damit die festen Beschriftungen
    /// ("Spezifikation (BT-24)" …) über den String Catalog übersetzt werden.
    private func headerRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryLine: String? {
        let s = document.summary
        var parts: [String] = []
        if let number = s.invoiceNumber { parts.append(number) }
        if let date = s.issueDate { parts.append(date) }
        if let seller = s.sellerName { parts.append(seller) }
        if let amount = s.payableAmount {
            parts.append("\(amount) \(s.currency ?? "")".trimmingCharacters(in: .whitespaces))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Filter

    private var filterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filtern (Wert, Element, BT-Nummer, Feldname) …", text: $filter)
                .textFieldStyle(.plain)
            Spacer()
            Toggle("Nur EN-16931-Felder", isOn: $termsOnly)
                .toggleStyle(.checkbox)
                .help("Nur Felder und Gruppen mit BT-/BG-Zuordnung anzeigen")
        }
        .padding(10)
    }

    // MARK: - Feldliste

    private var visibleFields: [EInvoiceField] {
        document.fields.filter { field in
            // Auch eine Zuordnung an einem Attribut (z.B. unitCode → BT-130)
            // zählt als EN-16931-Feld.
            if termsOnly && field.term == nil && field.attributeTerms.isEmpty { return false }
            guard !filter.isEmpty else { return true }
            return field.value.localizedCaseInsensitiveContains(filter)
                || field.element.localizedCaseInsensitiveContains(filter)
                || (field.term?.localizedCaseInsensitiveContains(filter) ?? false)
                || (field.termName?.localizedCaseInsensitiveContains(filter) ?? false)
                || field.attributes.contains {
                    $0.value.localizedCaseInsensitiveContains(filter)
                }
                || field.attributeTerms.contains {
                    $0.term.localizedCaseInsensitiveContains(filter)
                        || ($0.termName?.localizedCaseInsensitiveContains(filter) ?? false)
                }
        }
    }

    private var fieldList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                    InvoiceFieldRow(field: field, flat: !filter.isEmpty || termsOnly)
                }
            }
            .padding(12)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Eine Zeile: eingerückter Elementname, Wert, Attribute, rechts der
/// Business Term. Bei aktivem Filter entfällt die Einrückung (`flat`),
/// weil herausgefilterte Eltern die Baumstruktur sowieso zerreißen.
private struct InvoiceFieldRow: View {
    let field: EInvoiceField
    let flat: Bool

    private var isGroup: Bool { field.value.isEmpty && field.term?.hasPrefix("BG") == true }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(field.element)
                    .font(.caption.monospaced())
                    .foregroundStyle(field.value.isEmpty ? .secondary : .tertiary)
                if !field.value.isEmpty {
                    Text(field.value)
                        .font(.body)
                        .textSelection(.enabled)
                }
                ForEach(displayAttributes, id: \.name) { attribute in
                    // Attribute mit eigener BT-Nummer (z.B. unitCode → BT-130)
                    // zeigen die Zuordnung im Chip; der volle Name steht im
                    // Tooltip.
                    let match = field.attributeTerms.first { $0.attribute == attribute.name }
                    Text("\(attribute.name)=\(attribute.value)"
                         + (match.map { " · \($0.term)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .help(match?.termName ?? "")
                }
                if let note = field.valueNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .padding(.leading, flat ? 0 : CGFloat(field.level) * 16)

            Spacer(minLength: 16)

            if let term = field.term {
                HStack(spacing: 4) {
                    Text(term)
                        .font(.caption.weight(.semibold).monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(term.hasPrefix("BG") ? Color.orange.opacity(0.18)
                                                        : Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 4))
                    if let name = field.termName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
            }
        }
        .padding(.vertical, isGroup ? 5 : 2)
        .help(field.path)
    }

    /// xsi:schemaLocation ist reines Schema-Rauschen und bleibt der Pfad-Hilfe
    /// (Tooltip) vorbehalten.
    private var displayAttributes: [XMLTreeAttribute] {
        field.attributes.filter { $0.name != "xsi:schemaLocation" }
    }
}
