// Selbstbeendende Abnahme der echten SwiftUI-Ansichten im notarisierten Bundle.
// Ausschließlich expliziter Testmodus; normale App-Starts bleiben unberührt.
import AppKit
import EInvoiceCore
import SwiftUI
import TagExplosionCore

enum InvoiceValidationUITest {
    static var directory: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--invoice-ui-selftest"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    @MainActor static func run(at directory: URL) async {
        var checks: [[String: String]] = []
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 60, width: 900, height: 680),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Tag Explosion · Invoice UI Test"
        panel.isReleasedWhenClosed = false
        let profileMode = FileManager.default.fileExists(atPath: directory.appendingPathComponent("MINIMUM.xml").path)
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(profileMode ? 180 : 80)) } catch { return }
            let result = ["status": "failed", "error": "GUI-Gesamtfrist überschritten"]
            try? JSONSerialization.data(withJSONObject: result).write(to: directory.appendingPathComponent("ui-result.json"))
            panel.orderOut(nil)
            NSApp.hide(nil)
            NSApp.terminate(nil)
        }
        defer { watchdog.cancel() }
        do {
            NSApp.windows.filter { $0 != panel }.forEach { $0.orderOut(nil) }
            let bundle = try require(Bundle.main.resourceURL, "Bundle-Ressourcen fehlen")
                .appendingPathComponent("XRechnungValidator")
            let pdfOnly = CommandLine.arguments.contains("--pdf-only")
            let fullPDF = FileManager.default.fileExists(atPath: bundle.deletingLastPathComponent().appendingPathComponent("PDFValidator").path)
            var cases = [("ubl", InvoiceValidationStatus.passed), ("cii", .passed),
                         ("failed", .failed), ("unknown", .unsupported), ("invoice", fullPDF ? .failed : .partial)]
            let profiles = ["MINIMUM", "BASICWL", "BASIC", "EN16931", "EXTENDED"]
            let profileFiles = profiles.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".xml").path) }
            try expect(profileFiles.isEmpty || profileFiles.count == profiles.count, "Profilfixtures unvollständig")
            cases += profileFiles.map { ($0, .passed) }
            if profileMode {
                cases += [("FACTURX-schema", .failed), ("FACTURX-rule", .failed),
                          ("FACTURX-warning", .passedWithWarnings), ("FACTURX-pdf", fullPDF ? .failed : .partial)]
            }
            if pdfOnly {
                cases = [("HYBRID-valid", .passed), ("HYBRID-4f", .passed), ("HYBRID-failed", .failed), ("HYBRID-warning", .passedWithWarnings)]
            }
            for (name, expected) in cases {
                let isPDF = name == "invoice" || name == "FACTURX-pdf" || name.hasPrefix("HYBRID-")
                let url = directory.appendingPathComponent(name + (isPDF ? ".pdf" : ".xml"))
                let document = try EInvoiceReader.read(url: url)
                let model = InvoiceValidationModel(bundle: bundle)
                let content: AnyView
                if isPDF {
                    let entry = FileEntry(url: url, loaded: .ebook(EbookCoreFields(), cover: nil))
                    content = AnyView(EbookEditorView(entry: entry, validation: model).environment(AppModel()))
                } else {
                    let entry = FileEntry(url: url, loaded: .invoice(document))
                    content = AnyView(InvoiceView(entry: entry, validation: model))
                }
                let host = NSHostingView(rootView: content)
                panel.contentView = host
                panel.orderFront(nil)
                if isPDF {
                    try await press("ebook.invoice.tab", label: String(localized: "E-Rechnung"), in: host)
                }
                try await wait { model.url == url }
                try capture(host, at: directory.appendingPathComponent(name + "-before.png"))
                try await press("invoice.validation.start", in: host)
                try await wait { !model.isRunning && model.status != nil }
                try expect(model.status == expected || (expected == .passed && model.status == .passedWithWarnings), "Falscher Zustand: " + name)
                try expect(model.document?.summary.invoiceNumber == document.summary.invoiceNumber, "Anzeige/Quelle unterschiedlich")
                try capture(host, at: directory.appendingPathComponent(name + ".png"))
                if name == "ubl" {
                    panel.setContentSize(NSSize(width: 620, height: 600))
                    try capture(host, at: directory.appendingPathComponent("narrow.png"))
                    panel.setContentSize(NSSize(width: 900, height: 680))
                }
                if pdfOnly {
                    try expect(model.result?.pdf != nil, "PDF-Metadaten fehlen")
                    try expect(model.result?.xmlStatus == .passed, "XML-Teilergebnis fehlt")
                    try expect(model.result?.steps.contains { $0.id == "pdfa" && $0.status != .notChecked } == true, "PDF/A-Schritt fehlt")
                }
                let text = try require(await model.currentReport(), "Bericht fehlt")
                try expect(text.contains(InvoiceValidationPresentation.notice), "Vollständiger Gewährleistungshinweis fehlt")
                try expect(text.contains(InvoiceValidationPresentation.title(model.status, includesPDF: model.result?.pdf != nil)), "Berichtszustand fehlt")
                if profiles.contains(name), let result = model.result {
                    try expect(result.ruleSet == .facturX, "Falscher Profilregelstand")
                    try expect(InvoiceValidationPresentation.steps(result).count == 3, "Falsche Prüfkette")
                    try expect(text.contains("1.09.2"), "Regelversion fehlt")
                    try expect(!text.contains("[val-sch.2]"), "Nicht ausgeführte XRechnung-Regeln im Bericht")
                    try expect(document.warnings.isEmpty, "Widersprüchliche Grundprüfung")
                    try expect(text.contains(InvoiceValidationPresentation.standardNotice), "Standard-Nutzungshinweis fehlt")
                }
                try text.write(to: directory.appendingPathComponent(name + "-report.txt"), atomically: true, encoding: .utf8)
                checks.append(["case": name, "status": model.status!.rawValue, "button": "AXPress"])
                if pdfOnly && name == "HYBRID-valid" { panel.setContentSize(NSSize(width: 620, height: 600)) }
                if ["failed", "invoice", "MINIMUM", "EXTENDED", "HYBRID-valid", "HYBRID-failed", "HYBRID-warning"].contains(name) {
                    try await press("invoice.validation.report", in: host)
                    try await wait { panel.attachedSheet?.contentView != nil }
                    let reportHost = try require(panel.attachedSheet?.contentView, "Berichtsfenster fehlt")
                    try capture(reportHost, at: directory.appendingPathComponent(name + "-details.png"))
                    try await press("invoice.validation.report.close", in: reportHost)
                    try await wait { panel.attachedSheet == nil }
                }
                if pdfOnly && name == "HYBRID-valid" { panel.setContentSize(NSSize(width: 900, height: 680)) }
                if name == "ubl", let result = model.result {
                    // Reine Darstellung einer Warnung; kein behaupteter KoSIT-Nachweis.
                    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
                    object["status"] = "passedWithWarnings"
                    object["xmlStatus"] = "passedWithWarnings"
                    object["issues"] = [["severity": "warning", "code": "TEST_UI_WARNING", "message": "Warnungsdarstellung · presentation test"]]
                    let warning = try JSONDecoder().decode(InvoiceValidationResult.self, from: JSONSerialization.data(withJSONObject: object))
                    let warningModel = InvoiceValidationModel(bundle: bundle, initialResult: warning)
                    let warningHost = NSHostingView(rootView: InvoiceContentView(document: document, sourceURL: url, validation: warningModel))
                    panel.contentView = warningHost
                    try await wait { warningModel.status == .passedWithWarnings }
                    try capture(warningHost, at: directory.appendingPathComponent("warning-presentation.png"))
                    checks.append(["case": "warning-presentation", "status": "passedWithWarnings", "scope": "UI only"])
                }
                model.stopObserving()
            }
            let url = directory.appendingPathComponent("ubl.xml")
            let document = try EInvoiceReader.read(url: url)
            let cancelled = InvoiceValidationModel(bundle: bundle)
            let host = NSHostingView(rootView: InvoiceContentView(document: document, sourceURL: url, validation: cancelled))
            panel.contentView = host
            try await wait { cancelled.url == url }
            try await press("invoice.validation.start", in: host)
            try await wait { cancelled.isRunning }
            try capture(host, at: directory.appendingPathComponent("running.png"))
            try await press("invoice.validation.cancel", in: host)
            try await wait { !cancelled.isRunning }
            try expect(cancelled.status == .cancelled, "Abbruchzustand fehlt")
            try capture(host, at: directory.appendingPathComponent("cancelled.png"))
            checks.append(["case": "cancel", "status": "cancelled", "button": "AXPress"])
            cancelled.stopObserving()
            let broken = InvoiceValidationModel(bundle: directory.appendingPathComponent("missing-bundle"))
            let brokenHost = NSHostingView(rootView: InvoiceContentView(document: document, sourceURL: url, validation: broken))
            panel.contentView = brokenHost
            try await wait { broken.url == url }
            try await press("invoice.validation.start", in: brokenHost)
            try await wait { !broken.isRunning && broken.status != nil }
            try expect(broken.status == .technicalError, "Werkzeugfehler fehlt")
            try capture(brokenHost, at: directory.appendingPathComponent("tool-error.png"))
            checks.append(["case": "tool-error", "status": "technicalError"])
            broken.stopObserving()
            let json = try JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent("ui-result.json"))
        } catch {
            if let host = panel.contentView {
                try? capture(host, at: directory.appendingPathComponent("failure.png"))
            }
            let result = ["status": "failed", "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("ui-result.json"))
        }
        panel.orderOut(nil)
        panel.close()
        NSApp.hide(nil)
        NSApp.terminate(nil)
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "InvoiceUITest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        _ = try require(condition ? true : nil, message)
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while true {
            guard Date() < deadline else { throw NSError(domain: "InvoiceUITest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Zustand nicht erreicht"]) }
            if condition() {
                try await Task.sleep(for: .milliseconds(30))
                if condition() { return }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor private static func press(_ identifier: String, label: String? = nil, in host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        let directory = try require(directory, "Testverzeichnis fehlt")
        let nonce = UUID().uuidString
        let request = ["nonce": nonce, "identifier": identifier, "label": label ?? ""]
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("press-request.json"), options: .atomic)
        let responseURL = directory.appendingPathComponent("press-response.json")
        try await wait {
            guard let data = try? Data(contentsOf: responseURL),
                  let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return response["nonce"] as? String == nonce
        }
        let data = try Data(contentsOf: responseURL)
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try expect(response?["success"] as? Bool == true, "AXPress fehlgeschlagen: " + identifier)
    }

    @MainActor private static func capture(_ host: NSView, at url: URL) throws {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try require(host.bitmapImageRepForCachingDisplay(in: host.bounds), "Bildspeicher fehlt")
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try require(bitmap.representation(using: .png, properties: [:]), "PNG fehlt")
        try png.write(to: url)
    }
}
