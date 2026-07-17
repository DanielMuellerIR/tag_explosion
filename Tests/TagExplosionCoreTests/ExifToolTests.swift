// Roundtrip-Tests für Bild-Metadaten über exiftool (MWG-Tags).
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("ExifTool", .serialized)
struct ExifToolTests {

    @Test("Kernfelder schreiben und lesen (JPEG)")
    func coreFieldsRoundtripJPEG(  ) throws {
        let url = try Fixtures.workingCopy("cover.jpg")
        let original = try ExifTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Sonnenuntergang über Köln"
        edited.description = "Testbeschreibung mit Umlauten äöü"
        edited.keywords = ["Test", "Tag Explosion", "Häuser"]
        edited.creator = "Daniela Fotografin"
        edited.copyright = "© 2026 Test"
        edited.dateTimeOriginal = "2026:07:17 12:34:56"
        edited.rating = 4
        edited.gpsLatitude = "50.9375"
        edited.gpsLongitude = "6.9603"

        try ExifTool.writeCoreFields(url: url, fields: edited, original: original)
        let readBack = try ExifTool.readCoreFields(url: url)

        #expect(readBack.title == edited.title)
        #expect(readBack.description == edited.description)
        #expect(readBack.keywords == edited.keywords)
        #expect(readBack.creator == edited.creator)
        #expect(readBack.copyright == edited.copyright)
        #expect(readBack.dateTimeOriginal == edited.dateTimeOriginal)
        #expect(readBack.rating == 4)
        #expect(Double(readBack.gpsLatitude) ?? 0 > 50.9 && Double(readBack.gpsLatitude) ?? 0 < 51)
        #expect(Double(readBack.gpsLongitude) ?? 0 > 6.9 && Double(readBack.gpsLongitude) ?? 0 < 7)
    }

    @Test("Feld löschen (leerer Wert)")
    func deleteField() throws {
        let url = try Fixtures.workingCopy("cover.jpg")
        let empty = ImageCoreFields()
        var withTitle = empty
        withTitle.title = "Wegwerftitel"
        try ExifTool.writeCoreFields(url: url, fields: withTitle, original: empty)
        #expect(try ExifTool.readCoreFields(url: url).title == "Wegwerftitel")

        // Löschen: Titel zurück auf leer
        let current = try ExifTool.readCoreFields(url: url)
        var cleared = current
        cleared.title = ""
        try ExifTool.writeCoreFields(url: url, fields: cleared, original: current)
        #expect(try ExifTool.readCoreFields(url: url).title.isEmpty)
    }

    @Test("Alle Gruppen lesen enthält EXIF/XMP nach dem Schreiben")
    func readAllGroups() throws {
        let url = try Fixtures.workingCopy("cover.jpg")
        let original = try ExifTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Gruppentest"
        try ExifTool.writeCoreFields(url: url, fields: edited, original: original)

        let groups = try ExifTool.readAllGroups(url: url)
        let names = groups.map(\.name)
        #expect(names.contains { $0.hasPrefix("XMP") }, "Gruppen: \(names)")
        #expect(!groups.flatMap(\.fields).isEmpty)
        // Der Titel muss irgendwo auftauchen
        #expect(groups.flatMap(\.fields).contains { $0.value == "Gruppentest" })
    }

    @Test("PNG: XMP-Kernfelder funktionieren")
    func pngRoundtrip() throws {
        let url = try Fixtures.workingCopy("cover.png")
        let original = try ExifTool.readCoreFields(url: url)
        var edited = original
        edited.title = "PNG-Titel"
        edited.keywords = ["png", "test"]
        try ExifTool.writeCoreFields(url: url, fields: edited, original: original)
        let readBack = try ExifTool.readCoreFields(url: url)
        #expect(readBack.title == "PNG-Titel")
        #expect(readBack.keywords == ["png", "test"])
    }
}
