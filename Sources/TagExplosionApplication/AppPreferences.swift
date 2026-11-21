import Foundation
import TagExplosionCore

public struct AppPreferences {
    enum Setting: String, CaseIterable {
        case safeMode = "trashBackupBeforeSave"
        case automaticBackup = "autoBackupBeforeBatchSave"
        case imageSidecar = "writeImageSidecar"
        case id3v23 = "writeID3v23"
        case onlineServicesAllowed
        case privacyAcknowledged

        var defaultValue: Bool { self == .safeMode || self == .automaticBackup }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func enabled(_ setting: Setting) -> Bool {
        if defaults.object(forKey: setting.rawValue) == nil { return setting.defaultValue }
        return defaults.bool(forKey: setting.rawValue)
    }

    func set(_ enabled: Bool, for setting: Setting) {
        defaults.set(enabled, forKey: setting.rawValue)
    }

    var onlineLookupEnabled: Bool { enabled(.onlineServicesAllowed) && enabled(.privacyAcknowledged) }
    public var preferredID3Version: ID3Version { enabled(.id3v23) ? .v23 : .v24 }
}
