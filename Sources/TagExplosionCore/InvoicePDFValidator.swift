import EInvoiceCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct InvoicePDFValidationSummary: Codable, Sendable {
    public let engine: String
    public let rules: String
    public let profile: String?
    public let status: InvoiceValidationStatus
    public let pdfaStatus: InvoiceValidationResult.Step.Status
    public let embeddingStatus: InvoiceValidationResult.Step.Status
}

enum InvoicePDFValidator {
    static let inventorySHA256 = "0a6967172baf5e751e3d8449a765201bce19f0be39f76accede143c1a20b7e03"
    static let rules = "ZUGFeRD 2.5.2 / Factur-X 1.09.2 · Hybrid 2026-08-04"
    struct Result {
        let summary: InvoicePDFValidationSummary
        let issues: [InvoiceValidationResult.Issue]
    }
    struct PDFReport {
        let compliant: Bool
        let profile: String
        let issues: [InvoiceValidationResult.Issue]
    }
    private struct Policy: Decodable {
        struct Artifact: Decodable { let sha256: String }
        let engineVersion: String
        let jar: Artifact
    }
    enum Failure: Error, LocalizedError {
        case changedPackage, invalidReport
        var errorDescription: String? {
            switch self {
            case .changedPackage: "Das PDF-Prüfpaket fehlt oder wurde verändert."
            case .invalidReport: "veraPDF lieferte keinen vollständigen, widerspruchsfreien Prüfbericht."
            }
        }
    }

    static func inspect(_ bundle: URL) throws {
        let data = try Data(contentsOf: bundle.appendingPathComponent("legal/components.lock.json"))
        guard validationDigest(data) == inventorySHA256 else { throw Failure.changedPackage }
        let policy = try JSONDecoder().decode(Policy.self, from: data)
        guard policy.engineVersion == "1.30.3",
              try BackupJournal.sha256(of: bundle.appendingPathComponent("validator.jar")) == policy.jar.sha256 else {
            throw Failure.changedPackage
        }
    }

    static func validate(input: InvoiceValidationInput, bundle: URL, kositBundle: URL,
                         ruleSet: InvoiceValidationRuleSet,
                         timeout: TimeInterval, cancellation: ExternalToolRunner.Cancellation?) throws -> Result {
        try cancellation?.check()
        guard let pdf = input.pdf else { throw Failure.invalidReport }
        try inspect(bundle)
        _ = try InvoiceValidationPackage.inspect(kositBundle, cancellation: cancellation)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tagx-pdfa-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("invoice.pdf")
        try pdf.write(to: snapshot)
        var environment = ExternalToolRunner.utf8Environment()
        for key in ["JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "CLASSPATH"] { environment.removeValue(forKey: key) }
        let java = kositBundle.appendingPathComponent("runtime/Contents/Home/bin/java")
        let completion = try ExternalToolRunner.runResult(java.path, [
            "-Xmx512m", "-Djava.awt.headless=true", "-Dfile.encoding=UTF-8",
            "-Djavax.xml.accessExternalDTD=", "-Djavax.xml.accessExternalSchema=",
            "-Djavax.xml.accessExternalStylesheet=", "-Duser.home=\(temporary.path)",
            "-jar", bundle.appendingPathComponent("validator.jar").path,
            "--format", "xml", "--flavour", "0", "--defaultflavour", "3b",
            "--maxfailuresdisplayed", "5", snapshot.path,
        ], processTimeout: timeout, outputLimit: 8 * 1024 * 1024, environment: environment, cancellation: cancellation)
        guard [0, 1].contains(completion.exitCode) else { throw Failure.invalidReport }
        let report = try parseReport(completion.stdout)
        guard (completion.exitCode == 0) == report.compliant else { throw Failure.invalidReport }
        try cancellation?.check()
        try inspect(bundle)
        _ = try InvoiceValidationPackage.inspect(kositBundle, cancellation: cancellation)
        let document = try input.payload.document()
        let inspection = try EInvoiceReader.inspectPDF(pdf, selectedXML: input.payload.xml)
        var issues = try embeddingIssues(inspection, document: document, ruleSet: ruleSet)
        issues += try deliveryIssues(document: document, xml: input.payload.xml)
        let domestic = document.firstValue(term: "BT-40") == "DE" && document.firstValue(term: "BT-55") == "DE"
        let permitted = ["PDF/A-3a validation profile", "PDF/A-3b validation profile", "PDF/A-3u validation profile", "PDF/A-4f validation profile"].contains(report.profile)
        let pdfaPassed = report.compliant && permitted
        let pdfaSeverity: InvoiceValidationResult.Issue.Severity = .error
        issues += report.issues.map { .init(severity: pdfaSeverity, code: $0.code, location: $0.location, message: $0.message) }
        if !permitted {
            issues.append(.init(severity: pdfaSeverity, code: "BR-HYBRID-02", location: "PDF/A",
                message: "Der Hybridträger verlangt PDF/A-3 oder PDF/A-4f. Der geprüfte PDF/A-Teil ist nicht geeignet."))
        }
        let limited = issues.contains { $0.code == "PDF_INSPECTION_INCOMPLETE" }
        if !pdfaPassed && domestic {
            issues.append(.init(severity: .information, code: "BR-FX-DE-03", location: nil,
                message: "Der Standard beschreibt eine nationale Sonderbewertung von PDF/A-Abweichungen. Deren rechtliche Voraussetzungen werden hier nicht bestätigt; das technische PDF/A-Ergebnis bleibt getrennt ausgewiesen."))
        }
        let embeddingFailed = issues.contains { $0.severity == .error && !($0.code?.hasPrefix("PDFA:") ?? false) && $0.code != "BR-HYBRID-02" }
        let status: InvoiceValidationStatus
        if embeddingFailed || (!pdfaPassed && pdfaSeverity == .error) { status = .failed }
        else if !inspection.complete || limited || !pdfaPassed { status = .partial }
        else if issues.contains(where: { $0.severity == .warning }) { status = .passedWithWarnings }
        else { status = .passed }
        issues.append(.init(severity: .information, code: "PDF_VISUAL_CONTENT_NOT_CHECKED", location: nil,
            message: "Geprüft wurden PDF/A, technische Einbettung und Metadaten. Sichtbarer Rechnungsinhalt, Echtheit, Signaturen und steuerliche Voraussetzungen werden nicht bestätigt."))
        try cancellation?.check()
        return .init(summary: .init(engine: "veraPDF 1.30.3", rules: rules, profile: report.profile, status: status,
            pdfaStatus: pdfaPassed ? .passed : .failed,
            embeddingStatus: embeddingFailed ? .failed : inspection.complete && !limited ? .passed : .notChecked), issues: issues)
    }

    static func parseReport(_ data: Data) throws -> PDFReport {
        try XRechnungValidator.checkInput(data)
        let document = try XMLTools.document(from: data, path: "veraPDF-Bericht")
        guard let root = document.rootElement(), XMLTools.localName(root) == "report", XMLTools.namespace(of: root).isEmpty,
              let builds = XMLTools.firstElement(named: "buildInformation", in: root),
              let jobs = XMLTools.firstElement(named: "jobs", in: root),
              let batch = XMLTools.firstElement(named: "batchSummary", in: root) else { throw Failure.invalidReport }
        let versions = XMLTools.elements(named: "releaseDetails", in: builds)
        guard versions.count == 3, Set(versions.compactMap { XMLTools.attribute($0, "id") }) == Set(["core", "validation-model", "apps"]),
              versions.allSatisfy({ XMLTools.attribute($0, "version") == "1.30.3" }),
              XMLTools.attribute(batch, "totalJobs") == "1",
              ["failedToParse", "encrypted", "outOfMemory", "veraExceptions"].allSatisfy({ XMLTools.attribute(batch, $0) == "0" }),
              XMLTools.elements(named: "job", in: jobs).count == 1,
              let job = XMLTools.firstElement(named: "job", in: jobs),
              XMLTools.elements(named: "validationReport", in: job).count == 1,
              let report = XMLTools.firstElement(named: "validationReport", in: job),
              XMLTools.attribute(report, "jobEndStatus") == "normal",
              let compliant = XMLTools.attribute(report, "isCompliant"), ["true", "false"].contains(compliant),
              let profile = XMLTools.attribute(report, "profileName"),
              let details = XMLTools.firstElement(named: "details", in: report),
              let failedRules = Int(XMLTools.attribute(details, "failedRules") ?? ""), failedRules >= 0,
              let failedChecks = Int(XMLTools.attribute(details, "failedChecks") ?? ""), failedChecks >= 0,
              let passedChecks = Int(XMLTools.attribute(details, "passedChecks") ?? ""), passedChecks > 0,
              let totals = XMLTools.firstElement(named: "validationReports", in: batch),
              XMLTools.attribute(totals, "failedJobs") == "0",
              XMLTools.attribute(totals, "compliant") == (compliant == "true" ? "1" : "0"),
              XMLTools.attribute(totals, "nonCompliant") == (compliant == "true" ? "0" : "1") else { throw Failure.invalidReport }
        let rules = XMLTools.elements(named: "rule", in: details)
        guard (compliant == "true" && failedRules == 0 && failedChecks == 0 && rules.isEmpty)
            || (compliant == "false" && failedRules > 0 && failedChecks > 0 && rules.count == failedRules && rules.allSatisfy { XMLTools.attribute($0, "status") == "failed" }) else { throw Failure.invalidReport }
        let issues = rules.map { rule in
            let code = ["PDFA", XMLTools.attribute(rule, "specification") ?? "", XMLTools.attribute(rule, "clause") ?? "", XMLTools.attribute(rule, "testNumber") ?? ""].joined(separator: ":")
            let check = XMLTools.firstElement(named: "check", in: rule)
            return InvoiceValidationResult.Issue(severity: .error, code: code,
                location: check.map { XMLTools.text(of: "context", in: $0) },
                message: check.map { XMLTools.text(of: "errorMessage", in: $0) }.flatMap { $0.isEmpty ? nil : $0 }
                    ?? XMLTools.text(of: "description", in: rule))
        }
        return .init(compliant: compliant == "true", profile: profile, issues: issues)
    }

    private static func allElements(_ root: XMLElement) throws -> [XMLElement] {
        var result = [root]
        var index = 0
        while index < result.count && result.count < 100_000 {
            result += (result[index].children ?? []).compactMap { $0 as? XMLElement }
            index += 1
        }
        guard index == result.count else { throw Failure.invalidReport }
        return result
    }

    private static func deliveryIssues(document: EInvoiceDocument, xml: Data) throws -> [InvoiceValidationResult.Issue] {
        guard document.firstValue(term: "BT-40") == "DE", document.firstValue(term: "BT-3") != "386" else { return [] }
        guard document.firstValue(term: "BT-72") == nil else { return [] }
        var issues: [InvoiceValidationResult.Issue] = []
        if document.firstValue(term: "BT-80") == nil {
            issues.append(.init(severity: .warning, code: "BR-FX-DE-04", location: "BT-80",
                message: "Ohne Lieferdatum BT-72 sollte das Lieferland BT-80 angegeben sein."))
        }
        let headerPeriod = document.firstValue(term: "BT-73") != nil || document.firstValue(term: "BT-74") != nil
        let tree = try XMLTools.document(from: xml, path: "Rechnungs-XML")
        guard let root = tree.rootElement() else { throw Failure.invalidReport }
        let linesHavePeriod: Bool
        if document.syntax == .cii {
            let ram = "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
            let transaction = XMLTools.firstElement(named: "SupplyChainTradeTransaction", in: root)
            let lines = transaction.map { XMLTools.elements(named: "IncludedSupplyChainTradeLineItem", in: $0, namespaceURI: ram) } ?? []
            linesHavePeriod = !lines.isEmpty && lines.allSatisfy { line in
                let settlement = XMLTools.firstElement(named: "SpecifiedLineTradeSettlement", in: line, namespaceURI: ram)
                let period = XMLTools.firstElement(named: "BillingSpecifiedPeriod", in: settlement, namespaceURI: ram)
                return period.map { !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            }
        } else {
            let cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
            let lines = XMLTools.elements(named: document.syntax == .ublCreditNote ? "CreditNoteLine" : "InvoiceLine", in: root, namespaceURI: cac)
            linesHavePeriod = !lines.isEmpty && lines.allSatisfy { line in
                XMLTools.firstElement(named: "InvoicePeriod", in: line, namespaceURI: cac)
                    .map { !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            }
        }
        if !headerPeriod && !linesHavePeriod {
            issues.append(.init(severity: .warning, code: "BR-FX-DE-04", location: "BT-72/BG-14/BG-26",
                message: "Lieferdatum, Rechnungszeitraum oder ein Zeitraum in jeder Position fehlen."))
        }
        return issues
    }

    static func embeddingIssues(_ inspection: EInvoicePDFInspection, document: EInvoiceDocument,
                                ruleSet: InvoiceValidationRuleSet) throws -> [InvoiceValidationResult.Issue] {
        var issues: [InvoiceValidationResult.Issue] = []
        func add(_ code: String, _ message: String, _ severity: InvoiceValidationResult.Issue.Severity = .error) {
            issues.append(.init(severity: severity, code: code, location: "PDF-Einbettung/XMP", message: message))
        }
        if !inspection.complete { add("PDF_INSPECTION_INCOMPLETE", "Die Grenzen der Containerinspektion wurden erreicht. Nicht alle Einbettungen konnten geprüft werden.", .warning) }
        let invoices = inspection.attachments.filter(\.isInvoice)
        if invoices.count > 1 || (inspection.complete && invoices.count != 1) { add("BR-HYBRID-12", "Der PDF-Träger muss genau ein strukturiertes Rechnungsdokument enthalten.") }
        guard let selected = inspection.attachments.first(where: \.matchesSelectedXML) else {
            add("BR-HYBRID-12", "Das geprüfte XML lässt sich keiner eindeutigen PDF-Einbettung zuordnen.", inspection.complete ? .error : .warning)
            return issues
        }
        if inspection.attachments.filter(\.matchesSelectedXML).count != 1 { add("BR-HYBRID-12", "Dasselbe Rechnungs-XML ist mehrfach eingebettet.") }
        if !selected.inAssociatedFiles || !selected.inNameTree { add("BR-HYBRID-12", "Die Rechnung muss im AF-Array des Dokuments und im Namensbaum eingebettet sein.") }
        if selected.mimeType != "text/xml" { add("BR-HYBRID-12", "Der MIME-Typ der Rechnungsdatei muss text/xml sein.") }
        let isXRechnung = ruleSet.id == InvoiceValidationRuleSet.xrechnung.id
        let expectedProfile: String
        switch document.profile.guidelineID {
        case "urn:factur-x.eu:1p0:minimum": expectedProfile = "MINIMUM"
        case "urn:factur-x.eu:1p0:basicwl": expectedProfile = "BASIC WL"
        case "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic": expectedProfile = "BASIC"
        case "urn:cen.eu:en16931:2017": expectedProfile = "EN 16931"
        case "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended": expectedProfile = "EXTENDED"
        default: expectedProfile = isXRechnung ? "XRECHNUNG" : ""
        }
        let currentURI = "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
        let legacyURI = "urn:zugferd:pdfa:CrossIndustryDocument:invoice:1p0#"
        guard let metadata = inspection.metadata else { add("BR-HYBRID-03", "Die erforderlichen XMP-Metadaten fehlen oder können nicht sicher gelesen werden."); return issues }
        do { try XRechnungValidator.checkInput(metadata) }
        catch { add("BR-HYBRID-03", "Das XMP enthält eine nicht unterstützte XML-Deklaration."); return issues }
        guard let xmp = try? XMLTools.document(from: metadata, path: "PDF-XMP") else {
            add("BR-HYBRID-03", "Das XMP ist kein wohlgeformtes XML.")
            return issues
        }
        guard let root = xmp.rootElement() else { throw Failure.invalidReport }
        guard let elements = try? allElements(root) else {
            add("PDF_INSPECTION_INCOMPLETE", "Die XMP-Struktur überschreitet die Inspektionsgrenze.", .warning)
            return issues
        }
        let namespaces = [currentURI, legacyURI]
        var values: [String: [String]] = [:]
        var foundURIs = Set<String>()
        for element in elements {
            for uri in namespaces {
                if XMLTools.namespace(of: element) == uri {
                    foundURIs.insert(uri)
                    values[XMLTools.localName(element), default: []].append(element.stringValue ?? "")
                }
                for key in ["DocumentType", "DocumentFileName", "Version", "ConformanceLevel"] {
                    if let value = XMLTools.attribute(element, key, namespaceURI: uri) {
                        foundURIs.insert(uri)
                        values[key, default: []].append(value)
                    }
                }
            }
        }
        if foundURIs.count != 1 { add("BR-HYBRID-04", "Die Factur-X-/ZUGFeRD-XMP-Deklaration fehlt oder ist mehrdeutig.") }
        let legacy = foundURIs == [legacyURI]
        let uri = legacy ? legacyURI : currentURI
        let prefix = legacy ? "zf" : "fx"
        let expectedName = legacy ? "zugferd-invoice.xml" : isXRechnung ? "xrechnung.xml" : "factur-x.xml"
        if legacy && isXRechnung { add("BR-HYBRID-07", "Das XRechnung-Referenzprofil ist im veralteten ZUGFeRD-XMP-Schema nicht vorgesehen.") }
        if legacy { add("LEGACY_XMP", "Das veraltete, weiterhin unterstützte ZUGFeRD-XMP-Schema wird verwendet.", .warning) }
        let schemaURI = "http://www.aiim.org/pdfa/ns/schema#"
        let propertyURI = "http://www.aiim.org/pdfa/ns/property#"
        let schemas = elements.filter { XMLTools.localName($0) == "namespaceURI" && XMLTools.namespace(of: $0) == schemaURI && $0.stringValue == uri }
        guard schemas.count == 1, let schema = schemas.first?.parent as? XMLElement else {
            add("BR-HYBRID-03", "Das passende eingebettete XMP-Erweiterungsschema fehlt oder ist mehrdeutig.")
            return issues
        }
        if XMLTools.text(of: "prefix", in: schema, namespaceURI: schemaURI) != prefix { add("BR-HYBRID-05", "Das XMP-Erweiterungsschema deklariert nicht das vorgeschriebene Präfix.") }
        let definitions = try allElements(schema).filter { XMLTools.localName($0) == "name" && XMLTools.namespace(of: $0) == propertyURI }
        for (key, code, expected) in [("DocumentType", "BR-HYBRID-06", "INVOICE"), ("DocumentFileName", "BR-HYBRID-08", expectedName), ("Version", "BR-HYBRID-09", legacy ? "2p0" : "1.0")] {
            if values[key] != [expected] { add(code, "Das XMP-Feld \(key) fehlt, ist mehrdeutig oder entspricht nicht dem unterstützten Schema (\(expected)).") }
        }
        if values["ConformanceLevel"]?.count != 1 || !["MINIMUM", "BASIC WL", "BASIC", "EN 16931", "EXTENDED", "XRECHNUNG"].contains(values["ConformanceLevel"]?.first ?? "") { add("BR-HYBRID-07", "Die XMP-Profilangabe fehlt oder ist nicht zulässig.") }
        else if values["ConformanceLevel"] != [expectedProfile] { add("BR-HYBRID-15", "XMP-Profil und Profil des Rechnungs-XML stimmen nicht überein.", .warning) }
        for key in ["DocumentType", "DocumentFileName", "Version", "ConformanceLevel"] {
            let matches = definitions.filter { $0.stringValue == key }
            if matches.count != 1 || (matches.first?.parent as? XMLElement).map({ XMLTools.text(of: "valueType", in: $0, namespaceURI: propertyURI) != "Text" }) != false {
                add("BR-HYBRID-03", "Das Erweiterungsschema beschreibt das XMP-Feld \(key) nicht eindeutig als Text.")
            }
        }
        if selected.fileName != expectedName || (selected.unicodeFileName != nil && selected.unicodeFileName != expectedName) { add("BR-HYBRID-13", "Die eingebettete Rechnungsdatei trägt nicht den vorgeschriebenen Dateinamen \(expectedName).") }
        if values["DocumentFileName"] != [selected.fileName ?? ""] { add("BR-HYBRID-14", "XMP-Dateiname und tatsächlicher Dateiname stimmen nicht überein.", .warning) }
        let seller = document.firstValue(term: "BT-40")
        let buyer = document.firstValue(term: "BT-55")
        let reduced = ["MINIMUM", "BASIC WL"].contains(expectedProfile)
        let allowedRelations = reduced ? ["Data"] : (seller == "DE" || buyer == "DE" || isXRechnung) ? ["Alternative"] : ["Alternative", "Data", "Source"]
        if !allowedRelations.contains(selected.relationship ?? "") { add("BR-HYBRID-11", "Die AF-Beziehung entspricht nicht dem Profil und den erkennbaren Länderangaben.", .warning) }
        if seller == "DE", buyer == "DE", reduced { add(expectedProfile == "MINIMUM" ? "BR-HYBRID-DE-01" : "BR-HYBRID-DE-02", "Dieses reduzierte Profil ist für einen Hybridbeleg zwischen zwei deutschen Parteien nicht vorgesehen.") }
        if seller == "FR", buyer == "FR", isXRechnung { add("BR-HYBRID-FR-01", "Das XRechnung-Referenzprofil ist für einen Hybridbeleg zwischen zwei französischen Parteien nicht vorgesehen.") }
        let extensions = Set(["pdf", "txt", "gif", "tif", "tiff", "jpg", "jpeg", "csv", "xml", "json", "xls", "xlsx", "ods"])
        for attachment in inspection.attachments {
            let name = attachment.unicodeFileName ?? attachment.fileName ?? ""
            if !extensions.contains((name as NSString).pathExtension.lowercased()) && name != "factur-xedifact.edi" { add("HYBRID_ATTACHMENT_TYPE", "Nicht unterstützter zusätzlicher Dateityp im PDF: \(name).") }
        }
        return issues
    }
}
