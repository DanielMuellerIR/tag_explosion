import Foundation
import TagExplosionApplication
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct DesktopMain {
    @MainActor static func main() async {
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(2) }
        let output = DesktopOutput(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        let service = DesktopService()
        var failed = false
        await withTaskGroup(of: Void.self) { group in
            var framer = DesktopFramer()
            var running = 0
            do {
                while let chunk = try await BlockingInput.read(), !chunk.isEmpty {
                    for line in try framer.append(chunk) {
                        let request = try JSONDecoder().decode(DesktopRequest.self, from: line)
                        if running >= 64 { await group.next(); running -= 1 }
                        running += 1
                        group.addTask {
                            let response = await service.handle(request)
                            await output.send(response)
                        }
                    }
                }
            } catch { failed = true }
            // EOF oder ein Protokollfehler schneidet keine bereits angenommene
            // Dateiersetzung ab. Alle Aufträge werden vor dem Prozessende geerntet.
            await group.waitForAll()
        }
        if failed { exit(2) }
    }
}

private actor DesktopOutput {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func send(_ response: DesktopResponse) {
        do {
            var bytes = try JSONEncoder().encode(response)
            if bytes.count > DesktopFramer.maximumBytes {
                // Ein zu großer Bericht darf die Engine und ihre Editierpuffer
                // nicht beenden; der Aufrufer erhält einen strukturierten Fehler.
                bytes = Data("{\"id\":\(response.id),\"error\":{\"code\":\"message_too_large\",\"message\":\"Response exceeds the IPC size limit\"}}".utf8)
            }
            bytes.append(10)
            try handle.write(contentsOf: bytes)
        } catch { FileHandle.standardError.write(Data("Tag Explosion engine: disconnected output\n".utf8)) }
    }
}

private enum BlockingInput {
    static func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    #if canImport(Darwin)
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    #else
                    let count = Glibc.read(STDIN_FILENO, &buffer, buffer.count)
                    #endif
                    if count >= 0 {
                        continuation.resume(returning: count == 0 ? nil : Data(buffer.prefix(count)))
                        return
                    }
                    if errno == EINTR { continue }
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
            }
        }
    }
}
