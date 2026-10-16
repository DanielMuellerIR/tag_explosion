import EInvoiceCore
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct InvoiceValidationView: View {
    @Bindable var model: InvoiceValidationModel
    @State private var details = false
    @State private var notice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.isRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).foregroundStyle(color) }
                Text(model.isRunning ? String(localized: "Prüfung läuft …") : InvoiceValidationPresentation.title(model.status))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("invoice.validation.status")
                Spacer(minLength: 8)
                if model.isRunning {
                    Button(model.isCancelling ? String(localized: "Wird abgebrochen …") : String(localized: "Abbrechen")) { model.cancel() }
                        .disabled(model.isCancelling)
                        .accessibilityIdentifier("invoice.validation.cancel")
                } else {
                    Button("E-Rechnung prüfen") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("invoice.validation.start")
                }
                Button("Prüfbericht …") { details = true }
                    .disabled(model.status == nil || model.isRunning)
                    .accessibilityIdentifier("invoice.validation.report")
            }
            Text(model.result?.ruleSet.map { "\($0.standard) \($0.version) · \($0.configurationRelease)" } ?? String(localized: "Lokal · XSD und Schematron · XRechnung / ZUGFeRD / Factur-X"))
                .font(.caption).foregroundStyle(.secondary)
            if let result = model.result {
                if result.issues.contains(where: { $0.code == "REDUCED_PROFILE_SCOPE" }) {
                    Text("Reduziertes Profil: keine vollständige EN-16931-Prüfung.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if result.ruleSet?.id == InvoiceValidationRuleSet.facturX.id {
                    Text("Regelstand der Prüfung; die Profilkennung legt keine eindeutige Dokumentversion fest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if result.source?.url.pathExtension.lowercased() == "pdf" {
                    if result.xmlStatus != nil {
                        Text(InvoiceValidationPresentation.title(result.xmlStatus)).font(.callout.weight(.medium))
                    }
                    Text("Prüfumfang: Rechnungs-XML. PDF/A, Einbettung und sichtbarer PDF-Inhalt sind nicht geprüft.")
                        .font(.callout).foregroundStyle(.orange)
                } else if result.status == .partial {
                    Text("Nicht alle erforderlichen Prüfschritte wurden bestätigt.").font(.callout).foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    count(.error, result: result)
                    count(.warning, result: result)
                    count(.information, result: result)
                }.font(.caption)
                if result.status == .technicalError {
                    Text("Prüfpaket oder Werkzeug nicht verwendbar. Es liegt kein vollständiges Prüfergebnis vor.")
                        .font(.callout)
                } else if let first = result.issues.first(where: { $0.severity == .error }) {
                    Text(first.message).font(.callout).lineLimit(2).textSelection(.enabled)
                }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(InvoiceValidationPresentation.shortNotice).font(.caption).foregroundStyle(.secondary)
                Button("Gewährleistungshinweis") { notice = true }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
        .sheet(isPresented: $details) { InvoiceValidationReportView(model: model) }
        .popover(isPresented: $notice) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gewährleistungshinweis").font(.headline)
                Text(InvoiceValidationPresentation.notice).textSelection(.enabled)
                Text(InvoiceValidationPresentation.standardNotice).font(.caption).textSelection(.enabled)
                Button("Schließen") { notice = false }
            }.padding(20).frame(width: 460)
        }
    }

    private func count(_ severity: InvoiceValidationResult.Issue.Severity, result: InvoiceValidationResult) -> some View {
        HStack(spacing: 4) {
            Text(severity == .error ? String(localized: "Fehler") : severity == .warning ? String(localized: "Warnungen") : String(localized: "Informationen"))
            Text(result.issues.filter { $0.severity == severity }.count.formatted()).monospacedDigit()
        }
    }

    private var symbol: String {
        switch model.status {
        case .passed: "checkmark.circle.fill"
        case .failed, .technicalError: "xmark.circle.fill"
        case .passedWithWarnings, .partial, .stale: "exclamationmark.triangle.fill"
        default: "checkmark.shield"
        }
    }

    private var color: Color {
        switch model.status {
        case .passed: .green
        case .failed, .technicalError: .red
        case .passedWithWarnings, .partial, .stale: .orange
        default: .secondary
        }
    }
}

struct InvoiceValidationReportView: View {
    @Bindable var model: InvoiceValidationModel
    @Environment(\.dismiss) private var dismiss
    @State private var severity: InvoiceValidationResult.Issue.Severity?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("E-Rechnungsprüfung").font(.title2.weight(.semibold))
                    Text(InvoiceValidationPresentation.title(model.status)).font(.headline)
                    Text(model.url?.lastPathComponent ?? "").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("invoice.validation.report.close")
            }
            if let result = model.result {
                Text([result.ruleSet?.engine, result.ruleSet?.id, result.checkedAt].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let scenario = result.scenario { Text(scenario).font(.caption).textSelection(.enabled) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(InvoiceValidationPresentation.steps(result)) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(InvoiceValidationPresentation.step(step.id, ruleSet: result.ruleSet), systemImage: step.status == .passed ? "checkmark.circle" : step.status == .failed ? "xmark.circle" : "minus.circle")
                                .foregroundStyle(step.status == .passed ? Color.green : step.status == .failed ? .red : .secondary)
                                .help(step.id)
                            Text(InvoiceValidationPresentation.stepStatus(step.status)).foregroundStyle(.secondary)
                        }
                    }
                }.font(.caption)
                Picker("Meldungen", selection: $severity) {
                    Text("Alle Meldungen").tag(InvoiceValidationResult.Issue.Severity?.none)
                    Text("Fehler").tag(InvoiceValidationResult.Issue.Severity?.some(.error))
                    Text("Warnungen").tag(InvoiceValidationResult.Issue.Severity?.some(.warning))
                    Text("Informationen").tag(InvoiceValidationResult.Issue.Severity?.some(.information))
                }.pickerStyle(.segmented)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(result.issues.enumerated()).filter { severity == nil || $0.element.severity == severity }, id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(InvoiceValidationPresentation.severity(issue.severity)).fontWeight(.semibold)
                                    if let code = issue.code { Text(code).font(.callout.monospaced()) }
                                }.foregroundStyle(issue.severity == .error ? Color.red : issue.severity == .warning ? .orange : .secondary)
                                if let field = InvoiceValidationPresentation.field(for: issue, document: model.document) {
                                    Text(field).font(.callout.weight(.semibold))
                                }
                                Text(issue.message)
                                if let location = issue.location { Text(location).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        if result.issues.isEmpty { Text("Keine Meldungen aus den ausgeführten Prüfungen.").foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(model.error ?? InvoiceValidationPresentation.title(model.status)).textSelection(.enabled)
                Spacer()
            }
            DisclosureGroup("Gewährleistungshinweis") {
                Text(InvoiceValidationPresentation.notice).font(.caption).textSelection(.enabled).padding(.top, 4)
                Text(InvoiceValidationPresentation.standardNotice).font(.caption).textSelection(.enabled)
            }
            if let exportError { Text(exportError).foregroundStyle(.red).font(.caption) }
            HStack {
                Text(InvoiceValidationPresentation.shortNotice).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Bericht kopieren") {
                    Task {
                        guard let text = await model.currentReport() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }.disabled(model.status == .stale)
                Button("Bericht sichern …") {
                    saveReport()
                }.disabled(model.status == .stale)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 800, minHeight: 520, idealHeight: 660)
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "e-invoice-validation.txt"
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await model.saveReport(to: url) }
                catch { exportError = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
