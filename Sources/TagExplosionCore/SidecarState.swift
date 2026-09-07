import Foundation

/// Lesestand einer Sidecar (XMP oder LRC). Abwesenheit ist ein bekannter
/// Zustand; nur `unknown` verzichtet auf den Vergleich mit einem Lesestand.
public enum SidecarState: Sendable, Equatable {
    case unknown
    case absent
    case present(FileStamp)

    public static func current(of url: URL) -> SidecarState {
        FileStamp.current(of: url).map(SidecarState.present) ?? .absent
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
