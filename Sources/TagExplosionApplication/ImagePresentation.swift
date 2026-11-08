import Foundation
import TagExplosionCore

public enum ImagePresentation {
    public static func destinationText(_ destination: ImageWriteDestination) -> String {
        let name = destination.url.lastPathComponent
        switch destination.reason {
        case .original:
            return String(localized: "Änderungen werden in die Bilddatei geschrieben.")
        case .rawFormat:
            return String(localized: "Kamera-RAW: Änderungen gehen in die Sidecar \(name), das RAW bleibt unverändert.")
        case .formatNotWritable:
            return String(localized: "exiftool kann dieses Format nicht beschreiben: Änderungen gehen in die Sidecar \(name).")
        case .existingSidecar:
            return String(localized: "Änderungen gehen in die vorhandene Sidecar \(name), weil ihre Werte beim Lesen Vorrang haben.")
        case .setting:
            return String(localized: "Einstellung: Änderungen gehen in die Sidecar \(name) statt in die Bilddatei.")
        }
    }
}
