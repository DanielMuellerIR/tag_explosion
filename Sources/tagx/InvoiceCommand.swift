// tagx invoice — E-Rechnung anzeigen: Profil, Syntax, Dokumentart, Hinweise
// der Grundvalidierung und sämtliche Felder mit EN-16931-Feldbezeichnungen
// (BT-/BG-Nummern; Bestellungen mit Order-X-Bezeichnungen). Reine Anzeige,
// kein Schreibweg. Funktioniert für eigenständige XML-Dateien und für PDFs
// mit eingebetteter Rechnung bzw. Bestellung (ZUGFeRD/Factur-X/Order-X).
// Exit-Codes: 0 = ok (auch mit Hinweisen), 1 = Fehler, 3 = --strict und
// mindestens ein Hinweis.
import ArgumentParser
import EInvoiceCore
import Foundation
import TagExplosionCore

struct Invoice: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invoice",
        abstract: "Show e-invoice profile, warnings and all fields (ZUGFeRD, Factur-X, XRechnung, UBL, Peppol, Order-X).",
        discussion: """
            Basic validation only: missing EN 16931 mandatory fields and the \
            totals arithmetic (BT-106 … BT-115) are reported as warnings. \
            Exit code stays 0 unless --strict is given (then 3 on warnings).
            """
    )

    @Argument(help: "Invoice/order file(s): XML, or PDF with embedded invoice") var files: [String]
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .long, help: "Only groups and fields with an EN 16931 term (BT/BG) or an Order-X label")
    var termsOnly = false
    @Flag(name: .long, help: "Exit with code 3 if any document has warnings")
    var strict = false

    func run() throws {
        var documents: [(path: String, document: EInvoiceDocument)] = []
        for path in files {
            let url = try resolveFile(path)
            do {
                var document = try EInvoiceReader.read(url: url)
                // --terms-only wirkt VOR beiden Ausgabezweigen: Auch die
                // JSON-Ausgabe enthält dann nur Felder mit EN-16931-Zuordnung
                // (am Element oder an einem Attribut).
                if termsOnly {
                    document.fields = document.fields.filter {
                        $0.term != nil || $0.termName != nil || !$0.attributeTerms.isEmpty
                    }
                }
                documents.append((url.path, document))
            } catch let error as EInvoiceError {
                throw ValidationError("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if json {
            struct Report: Encodable {
                var file: String
                var invoice: EInvoiceDocument
            }
            try printJSON(documents.map { Report(file: $0.path, invoice: $0.document) })
        } else {
            for (index, entry) in documents.enumerated() {
                if documents.count > 1 {
                    if index > 0 { print("") }
                    print("== \(entry.path)")
                }
                printDocument(entry.document)
            }
        }

        // Hinweise sind kein Fehler: Die Ausgabe ist vollständig erfolgt,
        // nur der Exit-Code meldet sie — und nur auf Wunsch (--strict).
        if strict, documents.contains(where: { !$0.document.warnings.isEmpty }) {
            throw ExitCode(3)
        }
    }

    private func printDocument(_ document: EInvoiceDocument) {
        // Kopf: Standard, Profil, Syntax, Herkunft
        print("STANDARD: \(document.profile.standard)")
        print("PROFILE: \(document.profile.profile)")
        print("SYNTAX: \(document.syntax.rawValue)")
        print("KIND: \(document.documentKind.rawValue)")
        print("GUIDELINE: \(document.profile.guidelineID)")
        if let process = document.profile.businessProcessID {
            print("BUSINESS-PROCESS: \(process)")
        }
        if case .pdfEmbedded(let fileName) = document.source {
            print("PDF-ATTACHMENT: \(fileName)")
        }
        if let declaration = document.pdfDeclaration {
            var parts: [String] = []
            if let type = declaration.documentType { parts.append(type) }
            if let version = declaration.version { parts.append("Version \(version)") }
            if let level = declaration.conformanceLevel { parts.append(level) }
            if let name = declaration.documentFileName { parts.append(name) }
            print("PDF-XMP: \(parts.joined(separator: " · "))")
        }
        let summary = document.summary
        if let number = summary.invoiceNumber, let seller = summary.sellerName {
            var line = "SUMMARY: \(number) · \(seller)"
            if let amount = summary.payableAmount {
                line += " · \(amount) \(summary.currency ?? "")"
            }
            print(line)
        }
        // Hinweise der Grundvalidierung: Regelkennung, Business Term, Text.
        print("WARNINGS: \(document.warnings.count)")
        for warning in document.warnings {
            var line = "WARNING [\(warning.code)]"
            if let term = warning.term { line += " \(term)" }
            print("\(line): \(warning.message)")
        }
        print("---")

        // Felder: Einrückung nach Baumtiefe, rechts die Feldbezeichnung.
        // (--terms-only ist bereits in run() angewendet.)
        for field in document.fields {
            let indent = String(repeating: "  ", count: field.level)
            var line = indent + field.element
            if !field.value.isEmpty {
                line += " = \(field.value)"
            }
            let attributes = field.attributes
                .filter { $0.name != "xsi:schemaLocation" }
            if !attributes.isEmpty {
                // Attribute mit eigener BT-Nummer (z.B. unitCode → BT-130)
                // zeigen ihre Zuordnung direkt hinter dem Wert.
                let list = attributes.map { attribute in
                    var part = "\(attribute.name)=\(attribute.value)"
                    if let match = field.attributeTerms.first(
                        where: { $0.attribute == attribute.name }) {
                        part += " [\(match.term)"
                        if let name = match.termName { part += " \(name)" }
                        part += "]"
                    }
                    return part
                }.joined(separator: ", ")
                line += " (\(list))"
            }
            if let term = field.term {
                line += "  [\(term)"
                if let name = field.termName { line += " \(name)" }
                line += "]"
            } else if let name = field.termName {
                // Bestellungen: Order-X-Bezeichnung ohne BT-Nummer.
                line += "  [\(name)]"
            }
            if let note = field.valueNote {
                line += "  → \(note)"
            }
            print(line)
        }
    }
}
