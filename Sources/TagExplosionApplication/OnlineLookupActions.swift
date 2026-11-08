import Foundation
import TagExplosionCore

extension FileEntry {
    public var lookupFileInfo: LookupFileInfo {
        LookupFileInfo(url: url, data: TagData(properties: properties, artworks: [], audio: audio))
    }

    public func applyLookup(_ plan: LookupPlan, artwork: Artwork?) {
        properties = plan.apply(to: properties)
        guard MediaFormats.supportsEmbeddedArtwork(url), let artwork else { return }
        setFrontCover(artwork)
    }
}
