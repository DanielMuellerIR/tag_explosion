import EInvoiceCore
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Gemeinsame Rechnungsvalidierung")
struct InvoiceValidationServiceTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-core-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Originalkodierung und CDATA bleiben zwischen Anzeige und Prüfung erhalten")
    func originalBytes() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        let xml = InvoiceValidationFixtures.ubl.replacingOccurrences(of: "UTF-8", with: "UTF-16")
        let bytes = try #require(xml.data(using: .utf16))
        try bytes.write(to: url)
        let input = try InvoiceValidationInput.capture(at: url)
        #expect(input.payload.xml == bytes)
        #expect(input.source.xmlSHA256 == validationDigest(bytes))
        #expect(input.source.isCurrent(at: url))
        #expect(try input.payload.document().fields == EInvoiceReader.read(url: url).fields)
        #expect(try input.payload.document().summary.invoiceNumber == "ABC")
    }

    @Test("PDF-Auswahl und XML-Bytes stimmen mit der Anzeige überein",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable))
    func pdfSource() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.PDF")
        let bytes = Data(InvoiceValidationFixtures.ubl.utf8)
        let other = Data(InvoiceValidationFixtures.ubl.replacingOccurrences(of: "ABC", with: "XYZ").utf8)
        let pdf = InvoiceValidationFixtures.pdf(attachments: [("factur-x.xml", other), ("selected.xml", bytes)],
                                                declaredName: "selected.xml")
        try pdf.write(to: url)
        let input = try InvoiceValidationInput.capture(at: url)
        #expect(input.payload.xml == bytes)
        #expect(input.payload.source == .pdfEmbedded(fileName: "selected.xml"))
        #expect(input.source.fileSHA256 == validationDigest(pdf))
        #expect(input.source.xmlSHA256 == validationDigest(bytes))
        #expect(try input.payload.document().fields == EInvoiceReader.read(url: url).fields)
        #expect(input.payload.pdfDeclaration?.documentFileName == "selected.xml")
    }

    @Test("Gleich große Änderungen mit erhaltener Änderungszeit machen den Prüfstand ungültig")
    func changedBytes() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        try Data(InvoiceValidationFixtures.ubl.utf8).write(to: url)
        let input = try InvoiceValidationInput.capture(at: url)
        try Data(InvoiceValidationFixtures.ubl.replacingOccurrences(of: "ABC", with: "XYZ").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: input.source.stamp.modified)],
                                              ofItemAtPath: url.path)
        #expect(!input.source.isCurrent(at: url))
        let result = InvoiceValidationService.validate(input: input, bundle: dir)
        #expect(result.status == .stale)
        #expect(result.xmlStatus == nil)
        #expect(result.issues.contains { $0.code == "SOURCE_CHANGED" })
    }

    @Test("Profilrouting verwendet vollständige Kennungen und Namensräume")
    func exactProfiles() throws {
        let original = InvoiceValidationFixtures.ubl
        let known = try InvoiceValidationService.detectProfile(Data(original.utf8))
        #expect(InvoiceValidationService.expectedScenario(for: known) == "EN16931 XRechnung (UBL Invoice)")
        for xml in [
            original.replacingOccurrences(of: "xrechnung_3.0", with: "xrechnung_3.1"),
            original.replacingOccurrences(of: "xrechnung_3.0", with: "xrechnung_3.0_custom"),
            original.replacingOccurrences(of: "CommonBasicComponents-2", with: "ForeignComponents-2"),
            original.replacingOccurrences(of: "</b:CustomizationID>", with: "</b:CustomizationID><b:CustomizationID>other</b:CustomizationID>"),
            original.replacingOccurrences(of: "Invoice-2", with: "Order-2"),
        ] {
            #expect(InvoiceValidationService.expectedScenario(for: try InvoiceValidationService.detectProfile(Data(xml.utf8))) == nil)
        }
        let extensionXML = original.replacingOccurrences(of: InvoiceValidationFixtures.guideline,
            with: InvoiceValidationFixtures.guideline + "#conformant#urn:xeinkauf.de:kosit:extension:xrechnung_3.0")
        #expect(InvoiceValidationService.expectedScenario(for: try InvoiceValidationService.detectProfile(Data(extensionXML.utf8)))
                == "EN16931 XRechnung Extension (UBL Invoice)")
    }

    @Test("Unbekannt, XML-Fehler und fehlendes Werkzeug sind verschiedene Ergebnisse")
    func typedFailures() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        for (xml, status) in [
            ("<broken>", InvoiceValidationStatus.failed),
            (InvoiceValidationFixtures.ubl.replacingOccurrences(of: "xrechnung_3.0", with: "xrechnung_9.9"), .unsupported),
            (InvoiceValidationFixtures.ubl, .technicalError),
            ("<!DOCTYPE test><test/>", .technicalError),
        ] {
            try Data(xml.utf8).write(to: url)
            let result = InvoiceValidationService.validate(url: url, bundle: dir)
            #expect(result.status == status)
            #expect(result.xmlStatus == nil)
            let decoded = try JSONDecoder().decode(InvoiceValidationResult.self, from: JSONEncoder().encode(result))
            #expect(decoded.status == status)
            #expect(decoded.schemaVersion == 1)
            #expect(decoded.notice.contains("ohne Gewähr"))
        }
        let control = ExternalToolRunner.Cancellation()
        control.cancel()
        #expect(InvoiceValidationService.validate(url: url, bundle: dir, cancellation: control).status == .cancelled)
        #expect(InvoiceValidationService.validate(url: dir.appendingPathComponent("invoice.pdf"), bundle: dir,
                                                 cancellation: control).status == .cancelled)
    }

    @Test("Dateigrenzen und FIFOs werden vor blockierendem Lesen abgewiesen")
    func resourceLimits() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, size) in [("large.xml", InvoiceValidationInput.maximumXMLBytes),
                             ("large.pdf", InvoiceValidationInput.maximumPDFBytes)] {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size + 1))
            try handle.close()
            #expect(throws: InvoiceValidationInput.Failure.tooLarge) { try InvoiceValidationInput.capture(at: url) }
        }
        let fifo = dir.appendingPathComponent("input.xml")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: InvoiceValidationInput.Failure.notRegularFile) { try InvoiceValidationInput.capture(at: fifo) }
    }

    @Test("Begrenzte Prozessausgabe und Prozessfrist enden ohne positiven Rückgabewert", .timeLimit(.minutes(1)))
    func boundedProcess() throws {
        #expect(throws: ExternalToolRunner.ProcessOutputLimitError.exceeded) {
            try ExternalToolRunner.run("/bin/sh", ["-c", "while :; do printf '0123456789abcdef'; done"],
                                       processTimeout: 5, outputLimit: 1024)
        }
        #expect(throws: ExternalToolRunner.ProcessTimeoutError.exceeded) {
            try ExternalToolRunner.run("/bin/sh", ["-c", "sleep 5"], processTimeout: 0.05)
        }
    }

    @Test("Paket-Prüfsummen sind unabhängig von /var-/private-Alias und Symlink-Pfad")
    func packagePathAliases() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = dir.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("original bytes".utf8).write(to: content.appendingPathComponent("file.txt"))
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: content)
        #expect(try InvoiceValidationPackage.treeDigest(content) == InvoiceValidationPackage.treeDigest(alias))
        #expect(try InvoiceValidationPackage.treeDigest(content) == InvoiceValidationPackage.treeDigest(content.resolvingSymlinksInPath()))
    }

    private final class Gate: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func waitForStart() async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { [self] in
                    continuation.resume(returning: started.wait(timeout: .now() + 5) == .success)
                }
            }
        }
    }

    private static func completed(_ url: URL, source: InvoiceValidationSource? = nil) -> InvoiceValidationResult {
        .init(schemaVersion: 1, id: UUID(), checkedAt: "2026-10-16T00:00:00Z", status: .passed, xmlStatus: .passed,
              source: source, profile: nil, ruleSet: .xrechnung, scenario: url.lastPathComponent, steps: [], issues: [],
              notice: XRechnungValidationReport.notice)
    }

    @Test("Eine neue Auswahl verhindert die Veröffentlichung des alten Auftrags")
    func selectionRevision() async {
        let gate = Gate()
        let session = InvoiceValidationSession { url, _, _, _ in
            if url.lastPathComponent == "first.xml" {
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 10)
            }
            return Self.completed(url)
        }
        let first = Task { await session.validate(url: URL(fileURLWithPath: "/first.xml"), bundle: URL(fileURLWithPath: "/unused")) }
        defer { gate.release.signal() }
        let started = await gate.waitForStart()
        #expect(started)
        let second = await session.validate(url: URL(fileURLWithPath: "/second.xml"), bundle: URL(fileURLWithPath: "/unused"))
        gate.release.signal()
        #expect(await first.value == nil)
        #expect(second?.scenario == "second.xml")
        if case .finished(let result) = await session.state { #expect(result.scenario == "second.xml") }
        else { Issue.record("Der zweite Auftrag muss veröffentlicht sein") }
    }

    @Test("Abbruch unmittelbar vor Rückgabe verdrängt auch ein bereits berechnetes positives Ergebnis")
    func cancellationAtDelivery() async {
        for parentCancellation in [false, true] {
            let gate = Gate()
            let session = InvoiceValidationSession { url, _, _, _ in
                let result = Self.completed(url)
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 10)
                return result
            }
            let task = Task { await session.validate(url: URL(fileURLWithPath: "/invoice.xml"), bundle: URL(fileURLWithPath: "/unused")) }
            let started = await gate.waitForStart()
            #expect(started)
            if parentCancellation { task.cancel() } else { await session.cancel() }
            gate.release.signal()
            let result = await task.value
            #expect(result?.status == .cancelled)
            #expect(result?.xmlStatus == nil)
        }
    }

    @Test("Dateiänderung zwischen Berechnung und Auslieferung verwirft das positive Ergebnis")
    func changedAtDelivery() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        try Data(InvoiceValidationFixtures.ubl.utf8).write(to: url)
        let input = try InvoiceValidationInput.capture(at: url)
        let gate = Gate()
        let session = InvoiceValidationSession { url, _, _, _ in
            let result = Self.completed(url, source: input.source)
            gate.started.signal()
            _ = gate.release.wait(timeout: .now() + 10)
            return result
        }
        let task = Task { await session.validate(url: url, bundle: dir) }
        defer { gate.release.signal() }
        #expect(await gate.waitForStart())
        try Data(InvoiceValidationFixtures.ubl.replacingOccurrences(of: "ABC", with: "XYZ").utf8).write(to: url)
        gate.release.signal()
        let result = await task.value
        #expect(result?.status == .stale)
        #expect(result?.xmlStatus == nil)
        #expect(result?.steps.isEmpty == true)
    }
}
