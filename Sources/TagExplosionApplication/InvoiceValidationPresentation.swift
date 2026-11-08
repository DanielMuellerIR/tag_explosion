import Foundation
import EInvoiceCore
import TagExplosionCore

public enum InvoiceValidationPresentation {
    public struct DisplayedStep: Identifiable {
        public let id: String
        public let status: InvoiceValidationResult.Step.Status
    }

    public static func steps(_ result: InvoiceValidationResult) -> [DisplayedStep] {
        var ids = result.ruleSet?.requiredSteps ?? []
        for step in result.steps where !ids.contains(step.id) { ids.append(step.id) }
        return ids.map { id in .init(id: id, status: result.steps.first { $0.id == id }?.status ?? .notChecked) }
    }

    public static func stepStatus(_ status: InvoiceValidationResult.Step.Status) -> String {
        switch status {
        case .passed: String(localized: "Bestanden")
        case .failed: String(localized: "Fehlgeschlagen")
        case .notChecked: String(localized: "Nicht geprüft")
        }
    }
    public static func title(_ status: InvoiceValidationStatus?, includesPDF: Bool = false) -> String {
        switch status {
        case .passed: includesPDF ? String(localized: "Technische Prüfung bestanden") : String(localized: "XML-Prüfung bestanden")
        case .passedWithWarnings: includesPDF ? String(localized: "Technische Prüfung bestanden · Warnungen") : String(localized: "XML-Prüfung bestanden · Warnungen")
        case .failed: includesPDF ? String(localized: "Prüfung fehlgeschlagen") : String(localized: "XML-Prüfung fehlgeschlagen")
        case .unsupported: String(localized: "Profil nicht unterstützt")
        case .partial: String(localized: "Teilweise geprüft")
        case .cancelled: String(localized: "Prüfung abgebrochen")
        case .timedOut: String(localized: "Zeitlimit überschritten")
        case .technicalError: String(localized: "Technischer Prüffehler")
        case .stale: String(localized: "Datei verändert · erneut prüfen")
        case nil: String(localized: "Noch nicht geprüft")
        }
    }

    public static var shortNotice: String {
        String(localized: "Technische Prüfung ohne Gewähr. Keine Zusicherung rechtlicher oder steuerlicher Gültigkeit.")
    }

    public static var notice: String {
        String(localized: "Technische Prüfung ausschließlich gegen das genannte Regelpaket. Keine Zusicherung rechtlicher oder steuerlicher Gültigkeit und keine Garantie der Annahme durch einen Empfänger. Die Software und ihre Prüfergebnisse werden ohne Gewähr für Richtigkeit, Vollständigkeit oder Eignung für einen bestimmten Zweck bereitgestellt. Gewährleistung und Haftung sind nach Maßgabe der MIT-Lizenz im gesetzlich zulässigen Umfang ausgeschlossen; zwingende gesetzliche Haftung bleibt unberührt.")
    }

    public static var standardNotice: String {
        String(localized: "Diese Anwendung setzt den ZUGFeRD-/Factur-X-Standard um. Die Wiedergabe der zugrunde liegenden Veröffentlichung erfolgt nach den von FeRD veröffentlichten Nutzungsbedingungen mit Erlaubnis von CEN und DIN als Copyright-Inhabern.")
    }

    public static func severity(_ severity: InvoiceValidationResult.Issue.Severity) -> String {
        switch severity {
        case .error: String(localized: "Fehler")
        case .warning: String(localized: "Warnung")
        case .information: String(localized: "Information")
        }
    }

    public static func step(_ id: String, ruleSet: InvoiceValidationRuleSet? = nil) -> String {
        switch id {
        case "val-xml": String(localized: "XML-Syntax")
        case "val-xsd": String(localized: "XML-Schema (XSD)")
        case "val-sch.1": ruleSet?.id == InvoiceValidationRuleSet.facturX.id ? String(localized: "Factur-X-Profilregeln") : String(localized: "EN-16931-Regeln")
        case "val-sch.2": String(localized: "XRechnung-Regeln")
        case "pdfa": "PDF/A"
        case "pdf-embedding": String(localized: "PDF-Einbettung")
        default: id
        }
    }

    public static func field(for issue: InvoiceValidationResult.Issue, document: EInvoiceDocument?) -> String? {
        if issue.code == "BR-DE-15" { return "BT-10 · " + String(localized: "Käuferreferenz (z. B. Leitweg-ID)") }
        guard let location = issue.location else { return nil }
        // Nur eindeutige Zuordnung aus dem tatsächlich angezeigten XML;
        // ein unklarer XPath bleibt als Fundstelle sichtbar.
        let matches = document?.fields.filter { field in
            field.path == location || (field.term != nil && location.hasSuffix("/" + field.element))
        } ?? []
        let terms = Set(matches.compactMap(\.term))
        guard terms.count == 1, let field = matches.first, let term = terms.first else { return nil }
        return term + (field.termName.map { " · " + $0 } ?? "")
    }

    public static func report(result: InvoiceValidationResult?, status: InvoiceValidationStatus?, error: String?, url: URL?,
                       document: EInvoiceDocument? = nil) -> String {
        var lines = [String(localized: "E-Rechnungsprüfung"), url?.path ?? "", title(status, includesPDF: result?.pdf != nil)]
        lines.append(String(localized: "Das Ergebnis gilt ausschließlich für den dokumentierten Dateistand."))
        if let result {
            lines += [result.checkedAt, result.ruleSet?.id ?? "", result.ruleSet?.engine ?? "",
                      result.profile?.guidelineID ?? "", result.source.map { "XML SHA-256: " + $0.xmlSHA256 } ?? "",
                      result.source.map { "FILE SHA-256: " + $0.fileSHA256 } ?? ""]
            if let xmlStatus = result.xmlStatus, xmlStatus != result.status || result.pdf != nil { lines.append(title(xmlStatus)) }
            if let pdf = result.pdf {
                lines += [pdf.engine, pdf.rules, pdf.profile ?? "", title(pdf.status, includesPDF: true)]
                lines.append(String(localized: "Sichtbarer Inhalt, Signaturen und steuerliche Voraussetzungen sind nicht geprüft."))
            }
            for item in steps(result) { lines.append("\(step(item.id, ruleSet: result.ruleSet)) [\(item.id)]: \(stepStatus(item.status))") }
            for issue in result.issues {
                lines.append("\(severity(issue.severity)) [\(issue.code ?? "XML")]: \(issue.message)")
                if let field = field(for: issue, document: document) { lines.append(field) }
                if let location = issue.location { lines.append(location) }
            }
            if result.source?.url.pathExtension.lowercased() == "pdf", result.pdf == nil {
                lines.append(String(localized: "Prüfumfang: Rechnungs-XML. PDF/A, Einbettung und sichtbarer PDF-Inhalt sind nicht geprüft."))
            }
        }
        if let error { lines.append(error) }
        lines += ["", notice, "", standardNotice]
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
