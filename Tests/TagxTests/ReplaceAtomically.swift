// Fremde atomare Ersetzung simulieren — Gegenstück zu `TestFiles` im
// Core-Testziel (Testziele teilen keine Quellen). Linux-Foundation wirft bei
// `replaceItemAt` immer „file doesn't exist", deshalb dort `rename(2)`.
import Foundation
import TagExplosionCore
#if canImport(Glibc)
import Glibc
#endif

func replaceAtomically(_ url: URL, with replacement: URL) throws {
    #if canImport(Darwin)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
    #else
    guard rename(replacement.path, url.path) == 0 else {
        throw TagError.cannotOpen(path: url.path)
    }
    #endif
}
