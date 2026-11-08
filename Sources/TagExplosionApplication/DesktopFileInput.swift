import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum DesktopFileInput {
    static func read(at url: URL) throws -> Data {
        let limit = 16 * 1024 * 1024
        let path = url.resolvingSymlinksInPath().path
        // Eine zwischen Pfadprüfung und open ausgetauschte FIFO darf den
        // Worker nicht blockieren. Dateityp und Größe am geöffneten FD prüfen.
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DesktopFailure("invalid_file", "Only regular files can be read")
        }
        guard status.st_size <= limit else { throw DesktopFailure("input_too_large", "Input exceeds 16 MiB") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DesktopFailure("input_too_large", "Input exceeds 16 MiB") }
        return data
    }
}
