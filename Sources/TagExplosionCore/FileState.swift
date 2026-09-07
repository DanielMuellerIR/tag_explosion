import Foundation

/// Lesestand einer Datei. Abwesenheit ist ein bekannter
/// Zustand; nur `unknown` verzichtet auf den Vergleich mit einem Lesestand.
public enum FileState: Sendable, Equatable {
    case unknown
    case absent
    case present(FileStamp)

    public static func current(of url: URL) -> FileState {
        FileStamp.current(of: url).map(FileState.present) ?? .absent
    }

    public func requireUnchanged(at url: URL) throws {
        switch self {
        case .unknown: return
        case .absent:
            // attributesOfItem erkennt auch eine inzwischen angelegte,
            // aber ins Leere zeigende Verknüpfung.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                throw TagError.fileChangedOnDisk(path: url.path)
            }
        case .present(let stamp):
            guard FileStamp.current(of: url) == stamp else {
                throw TagError.fileChangedOnDisk(path: url.path)
            }
        }
    }
}

/// Kompatibler Name für bestehende XMP-/LRC-Aufrufer.
public typealias SidecarState = FileState
