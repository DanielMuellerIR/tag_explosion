import Foundation
import TagExplosionTestSupport
import TagExplosionCore
import Testing
@testable import TagExplosionApp

@Suite("Rechnungsprüfung in der App", .serialized) @MainActor
struct InvoiceValidationModelTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-app-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "InvoiceModelTest", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Der Dateiwächter folgt der neuen Auswahl und verwirft ihr Ergebnis nach Änderung")
    func selectionAndFileChange() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.xml")
        let second = dir.appendingPathComponent("second.xml")
        let bytes = Data(InvoiceValidationFixtures.ubl.replacingOccurrences(of: "xrechnung_3.0", with: "xrechnung_9.9").utf8)
        try bytes.write(to: first)
        try bytes.write(to: second)
        let model = InvoiceValidationModel(bundle: dir)
        defer { model.stopObserving() }
        model.observe(first)
        model.start()
        try await wait { !model.isRunning }
        #expect(model.status == .unsupported)
        model.observe(second)
        #expect(model.status == nil)
        model.start()
        try await wait { !model.isRunning }
        #expect(model.result?.source?.url == second)
        let report = try #require(await model.currentReport())
        #expect(report.contains("XML SHA-256"))
        #expect(report.contains(InvoiceValidationPresentation.notice))
        try Data(InvoiceValidationFixtures.ubl.utf8).write(to: second)
        try await wait { model.status == .stale }
        #expect(model.result == nil)
        #expect(model.isRunning == false)
    }

    @Test("Abbruch und Schließen liefern keinen späten Erfolg")
    func cancelAndDisappear() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        try Data(InvoiceValidationFixtures.ubl.utf8).write(to: url)
        let model = InvoiceValidationModel(bundle: dir)
        model.observe(url)
        model.start()
        model.cancel()
        try await wait { !model.isRunning }
        #expect(model.status == .cancelled)
        model.start()
        model.stopObserving()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.status == nil)
        #expect(model.result == nil)
    }

    @Test("Werkzeugfehler bleiben exportierbar und enthalten den vollständigen Hinweis")
    func toolErrorReport() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        try Data(InvoiceValidationFixtures.ubl.utf8).write(to: url)
        let model = InvoiceValidationModel(bundle: dir)
        defer { model.stopObserving() }
        model.observe(url)
        model.start()
        try await wait { !model.isRunning }
        #expect(model.status == .technicalError)
        let report = try #require(await model.currentReport())
        #expect(report.contains(InvoiceValidationPresentation.title(.technicalError)))
        #expect(report.contains(InvoiceValidationPresentation.notice))
    }

    @Test("Berichtsexport schützt Rechnung, Symlinks und Hardlinks")
    func reportCannotReplaceInvoice() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        let bytes = Data(InvoiceValidationFixtures.ubl.utf8)
        try bytes.write(to: url)
        let symbolic = dir.appendingPathComponent("symbolic.txt")
        let hard = dir.appendingPathComponent("hard.txt")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: url)
        try FileManager.default.linkItem(at: url, to: hard)
        let model = InvoiceValidationModel(bundle: dir)
        defer { model.stopObserving() }
        model.observe(url)
        model.start()
        try await wait { !model.isRunning }
        for target in [url, symbolic, hard] {
            await #expect(throws: InvoiceValidationModel.ExportFailure.sourceFile) { try await model.saveReport(to: target) }
        }
        #expect(try Data(contentsOf: url) == bytes)
        let report = dir.appendingPathComponent("report.txt")
        try await model.saveReport(to: report)
        #expect(try String(contentsOf: report, encoding: .utf8).contains(InvoiceValidationPresentation.notice))
    }

    @Test("App-Ende wartet auch auf bereits invalidierte Aufträge")
    func applicationShutdown() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invoice.xml")
        try Data(InvoiceValidationFixtures.ubl.utf8).write(to: url)
        let first = InvoiceValidationModel(bundle: dir)
        let second = InvoiceValidationModel(bundle: dir)
        defer { first.stopObserving(); second.stopObserving() }
        first.observe(url); second.observe(url)
        first.start(); second.start()
        first.reset()
        await InvoiceValidationModel.finishAllJobs(terminating: false)
        #expect(!InvoiceValidationModel.hasActiveJobs)
        #expect(first.status == nil)
        #expect(second.status == .cancelled)
        first.start()
        try await wait { !first.isRunning }
        let destination = dir.appendingPathComponent("shutdown-report.txt")
        let export = Task { try await first.saveReport(to: destination) }
        try await wait { InvoiceValidationModel.hasActiveJobs || FileManager.default.fileExists(atPath: destination.path) }
        await InvoiceValidationModel.finishAllJobs(terminating: false)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!InvoiceValidationModel.hasActiveJobs)
        try await export.value
    }
}
