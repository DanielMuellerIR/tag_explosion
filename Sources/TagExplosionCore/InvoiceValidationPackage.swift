import EInvoiceCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct InvoiceValidationRuleSet: Codable, Sendable, Equatable {
    public struct Profile: Codable, Sendable, Equatable {
        public let syntax: EInvoiceSyntax
        public let guidelineID: String
        public let scenario: String
    }

    public let id: String
    public let standard: String
    public let version: String
    public let configurationRelease: String
    public let engine: String
    public let inventorySHA256: String
    public let profiles: [Profile]

    public var requiredSteps: [String] {
        id == Self.facturX.id ? ["val-xml", "val-xsd", "val-sch.1"] : ["val-xml", "val-xsd", "val-sch.1", "val-sch.2"]
    }

    public static let supported: [Self] = [.xrechnung, .facturX]
    public static let trustedInventorySHA256 = "58854808b0a90a7ab09f9d38128f515bcfcbf02c7622f0435b675f9d2a382306"

    public static let xrechnung = Self(id: "xrechnung-3.0.2-2026-08-31", standard: "XRechnung", version: "3.0.2",
        configurationRelease: "2026-08-31", engine: "KoSIT Validator 1.6.3",
        inventorySHA256: trustedInventorySHA256, profiles: xrechnungProfiles)

    public static let facturX = Self(id: "facturx-1.09.2-zugferd-2.5.2", standard: "ZUGFeRD / Factur-X",
        version: "2.5.2 / 1.09.2", configurationRelease: "2026-08-04", engine: "KoSIT Validator 1.6.3",
        inventorySHA256: trustedInventorySHA256, profiles: [
            ("MINIMUM", "urn:factur-x.eu:1p0:minimum"),
            ("BASICWL", "urn:factur-x.eu:1p0:basicwl"),
            ("BASIC", "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic"),
            ("EN16931", "urn:cen.eu:en16931:2017"),
            ("EXTENDED", "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended"),
        ].map { .init(syntax: .cii, guidelineID: $0.1, scenario: "Factur-X 1.09.2 / ZUGFeRD 2.5.2 (\($0.0))") })

    private static let xrechnungProfiles: [Profile] = {
        let base = "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"
        let extensionID = base + "#conformant#urn:xeinkauf.de:kosit:extension:xrechnung_3.0"
        return [
            .init(syntax: .cii, guidelineID: base, scenario: "EN16931 XRechnung (CII)"),
            .init(syntax: .ublInvoice, guidelineID: base, scenario: "EN16931 XRechnung (UBL Invoice)"),
            .init(syntax: .ublCreditNote, guidelineID: base, scenario: "EN16931 XRechnung (UBL CreditNote)"),
            .init(syntax: .cii, guidelineID: extensionID, scenario: "EN16931 XRechnung Extension (CII)"),
            .init(syntax: .ublInvoice, guidelineID: extensionID, scenario: "EN16931 XRechnung Extension (UBL Invoice)"),
        ]
    }()
}

enum InvoiceValidationPackage {
    enum Failure: Error, LocalizedError {
        case changed(String)
        var errorDescription: String? {
            switch self {
            case .changed(let component): "Das Prüfpaket ist unvollständig oder verändert: \(component)."
            }
        }
    }
    struct Manifest: Decodable {
        let validatorVersion: String
        let configurationRelease: String
        let xrechnungVersion: String
        let facturXVersion: String
        let zugferdVersion: String
        let architecture: String
        let packaging: String
    }

    private struct Policy: Decodable {
        let packagedJarSHA256: String
        let configurationTreeSHA256: String
        let runtimeTreeSHA256: [String: String]
        let packaging: String
    }

    static func inspect(_ bundle: URL, cancellation: ExternalToolRunner.Cancellation? = nil) throws -> InvoiceValidationRuleSet {
        try cancellation?.check()
        let ruleSet = InvoiceValidationRuleSet.xrechnung
        let policyData = try Data(contentsOf: bundle.appendingPathComponent("legal/components.lock.json"))
        guard validationDigest(policyData) == ruleSet.inventorySHA256 else { throw Failure.changed("Lizenzinventar") }
        let policy = try JSONDecoder().decode(Policy.self, from: policyData)
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        guard manifest.validatorVersion == "1.6.3", manifest.configurationRelease == ruleSet.configurationRelease,
              manifest.xrechnungVersion == ruleSet.version, manifest.packaging == policy.packaging,
              manifest.facturXVersion == "1.09.2", manifest.zugferdVersion == "2.5.2",
              manifest.architecture == architecture,
              FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("runtime/Contents/Home/bin/java").path)
        else { throw Failure.changed("Version oder Laufzeitarchitektur") }
        guard try BackupJournal.sha256(of: bundle.appendingPathComponent("validator.jar")) == policy.packagedJarSHA256
        else { throw Failure.changed("KoSIT-JAR") }
        guard try treeDigest(bundle.appendingPathComponent("configuration"), cancellation: cancellation) == policy.configurationTreeSHA256
        else { throw Failure.changed("Regeldateien") }
        guard try treeDigest(bundle.appendingPathComponent("runtime"), cancellation: cancellation) == policy.runtimeTreeSHA256[architecture]
        else { throw Failure.changed("Java-Laufzeit") }
        try cancellation?.check()
        return ruleSet
    }

    /// Dieselbe kanonische Darstellung wie das Python-Lizenzinventar.
    /// Symlinks werden als Herstellerverweise erfasst, niemals durchlaufen.
    static func treeDigest(_ directory: URL, cancellation: ExternalToolRunner.Cancellation? = nil) throws -> String {
        let fm = FileManager.default
        // Foundation behält bei /var teils den Alias, während der Enumerator
        // /private/var liefert. Relative Namen brauchen dieselbe physische Basis.
        guard let resolved = realpath(directory.path, nil) else { throw Failure.changed("Dateibaum") }
        let base = String(cString: resolved) + "/"
        free(resolved)
        let directory = URL(fileURLWithPath: String(base.dropLast()))
        var enumerationError: (any Error)?
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw XRechnungValidator.Failure.unavailableBundle
        }
        var entries: [String: String] = [:]
        for case let url as URL in walker {
            try cancellation?.check()
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard url.path.hasPrefix(base) else { throw Failure.changed("Dateibaum") }
            let relative = String(url.path.dropFirst(base.count))
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                walker.skipDescendants()
                entries[relative] = "{\"symlink\": \(jsonString(try fm.destinationOfSymbolicLink(atPath: url.path)))}"
            case .typeRegular:
                guard let hash = try BackupJournal.sha256(of: url) else { throw XRechnungValidator.Failure.unavailableBundle }
                entries[relative] = "{\"sha256\": \(jsonString(hash))}"
            case .typeDirectory: break
            default: throw XRechnungValidator.Failure.unavailableBundle
            }
        }
        if let enumerationError { throw enumerationError }
        let json = "{" + entries.keys.sorted().map { "\(jsonString($0)): \(entries[$0]!)" }.joined(separator: ", ") + "}"
        return validationDigest(Data(json.utf8))
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32, 127...:
                for unit in String(scalar).utf16 { result += String(format: "\\u%04x", unit) }
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
