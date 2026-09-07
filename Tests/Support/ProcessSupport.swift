// Gemeinsame Prozessausführung für Core- und CLI-Integrationstests.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CapturedProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum TestProcessError: Error {
    case timedOut(executable: String)
    case missingCLI(beside: String)
}

/// Ausgaben landen in eigenen temporären Dateien. Damit können weder volle
/// Pipes noch von Kindprozessen geerbte Pipe-Enden den Test blockieren.
/// Die Frist gilt für den gestarteten Prozess; sie wird nicht als Erfolg gewertet.
public func runCapturedProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL,
    environment: [String: String] = [:],
    timeout: TimeInterval = 30
) throws -> CapturedProcessResult {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tagx-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let errors = try FileHandle(forWritingTo: errorURL)
    defer { try? errors.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
    process.standardOutput = output
    process.standardError = errors
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            // Nur das von diesem Aufruf gestartete und noch laufende Kind.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        throw TestProcessError.timedOut(executable: executable)
    }
    return CapturedProcessResult(status: process.terminationStatus,
        stdout: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
}

private final class TestBundleMarker: NSObject {}

public enum TagxTestProcess {
    public static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let executable: Result<URL, any Error> = Result {
        // Swift Testing kann unter einem SwiftPM-Helfer laufen; argv[0]
        // bezeichnet dann nicht das Testbinary. Die Markerklasse liegt im
        // geladenen Testbundle und liefert dessen tatsächlichen Buildordner.
        let bundle = Bundle(for: TestBundleMarker.self).bundleURL
        #if os(macOS)
        let directory = bundle.deletingLastPathComponent()
        #else
        // Corelibs-Foundation liefert das Verzeichnis des Testbinarys direkt.
        let directory = bundle
        #endif
        let candidate = directory.appendingPathComponent("tagx")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw TestProcessError.missingCLI(beside: bundle.path)
        }
        return candidate
    }

    public static func binaryURL() throws -> URL { try executable.get() }
}

/// Führt das durch die Testtarget-Abhängigkeit gebaute CLI aus.
public func runTagx(arguments: [String], environment: [String: String] = [:]) throws -> CapturedProcessResult {
    try runCapturedProcess(executable: TagxTestProcess.binaryURL().path,
        arguments: arguments, currentDirectory: TagxTestProcess.repoRoot, environment: environment)
}
