// Dateihelfer für Tests, die plattformabhängige Foundation-Lücken umgehen.
import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum TestFiles {
    /// Ersetzt `url` atomar durch `replacement` — so wie ein fremdes Programm
    /// eine Datei austauscht (neue Inode, gleicher Pfad). Unter macOS über
    /// `replaceItemAt`; Linux-Foundation wirft dort „file doesn't exist",
    /// deshalb dort ein direktes `rename(2)`, das dasselbe bewirkt.
    @discardableResult
    public static func replaceAtomically(_ url: URL, with replacement: URL) throws -> URL {
        #if canImport(Darwin)
        return try FileManager.default.replaceItemAt(url, withItemAt: replacement) ?? url
        #else
        guard rename(replacement.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
        #endif
    }
}
