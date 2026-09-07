import Foundation
import Testing
import TagExplosionTestSupport

@Suite("Test-Prozessausführung")
struct ProcessSupportTests {
    @Test("Prozesshelfer erfasst große stdout- und stderr-Ausgaben vollständig")
    func processHelperCapturesBothStreams() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let byteCount = 1_048_576
        let command = """
        dd if=/dev/zero bs=\(byteCount) count=1 2>/dev/null
        dd if=/dev/zero bs=\(byteCount) count=1 1>&2 2>/dev/null
        """

        let result = try runCapturedProcess(
            executable: "/bin/sh", arguments: ["-c", command], currentDirectory: root)

        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == byteCount)
        #expect(result.stderr.utf8.count == byteCount)
    }

    @Test("Ein hängender Testprozess endet mit einem Fristfehler")
    func processDeadline() throws {
        let start = ContinuousClock.now
        #expect(throws: TestProcessError.self) {
            try runCapturedProcess(executable: "/bin/sleep", arguments: ["10"],
                currentDirectory: TagxTestProcess.repoRoot, timeout: 0.05)
        }
        #expect(start.duration(to: .now) < .seconds(3))
    }
}
