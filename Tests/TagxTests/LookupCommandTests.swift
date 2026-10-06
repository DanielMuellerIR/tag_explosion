// CLI-Regressionen für `tagx lookup` ohne Netz: Verweigerung ohne
// TAGX_ONLINE (Exit 1 mit Hinweis, bevor irgendetwas gelesen wird),
// Datenschutztext, Argumentprüfung.
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore
@testable import tagx

@Suite("tagx lookup")
struct LookupCommandTests {
    @Test("Lookup-Cover ersetzt nur das erste Bild und erhält weitere Bilder")
    func preservesOtherArtworks() {
        let old = Artwork(data: Data([1]), pictureType: "Front Cover")
        let booklet = Artwork(data: Data([2]), pictureType: "Leaflet Page")
        let cover = Artwork(data: Data([3]), pictureType: "Front Cover")
        #expect(Lookup.replacingFront(cover, in: [old, booklet]) == [cover, booklet])
        #expect(Lookup.replacingFront(cover, in: []) == [cover])
        #expect(Lookup.replacingFront(cover, in: [booklet, old]) == [booklet, cover])
        #expect(Lookup.replacingFront(cover, in: [booklet]) == [cover, booklet])
    }

    @Test("Ohne TAGX_ONLINE: Exit 1 mit Hinweis, auch bei nicht existierender Datei")
    func refusesWithoutConsent() throws {
        let result = try runTagx(arguments: ["lookup", "/nirgends/datei.mp3"], environment: ["TAGX_ONLINE": ""])
        #expect(result.status == 1)
        #expect(result.stderr.contains("Online services are disabled"))
        #expect(result.stderr.contains("TAGX_ONLINE=1"))
        #expect(result.stdout.isEmpty)
    }

    @Test("--privacy druckt beide Hinweise ohne Datei und ohne Freigabe")
    func privacyNotice() throws {
        let result = try runTagx(arguments: ["lookup", "--privacy"], environment: ["TAGX_ONLINE": ""])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("musicbrainz.org"))
        #expect(result.stdout.contains("api.acoustid.org"))
        #expect(result.stdout.contains("Beim Nachschlagen"))
    }

    @Test("Argumentfehler: keine Datei, unbekannte Quelle, --choose 0")
    func usageErrors() throws {
        let noFile = try runTagx(arguments: ["lookup"], environment: ["TAGX_ONLINE": "1"])
        #expect(noFile.status == 64 && noFile.stderr.contains("at least one media file"))
        let badSource = try runTagx(arguments: ["lookup", "--source", "spotify", "x.mp3"], environment: ["TAGX_ONLINE": "1"])
        #expect(badSource.status == 64)
        let badChoice = try runTagx(arguments: ["lookup", "--choose", "0", "x.mp3"], environment: ["TAGX_ONLINE": "1"])
        #expect(badChoice.status == 64 && badChoice.stderr.contains("--choose"))
    }


}
