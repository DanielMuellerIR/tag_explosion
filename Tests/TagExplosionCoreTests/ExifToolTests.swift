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

    @Test("Ungültige Bewertung und GPS-Werte werden vor exiftool abgelehnt")
    func invalidCoreFieldsAreRejected() throws {
        let invalidValues: [(rating: Int, latitude: String, longitude: String)] = [
            (99, "", ""),
            (-1, "91", "0"),
            (-1, "0", "181"),
            (-1, "keine Zahl", "0"),
            (-1, "50", ""),
        ]
        for invalid in invalidValues {
            let url = try Fixtures.workingCopy("cover.jpg")
            let original = try ExifTool.readCoreFields(url: url)
            let bytesBefore = try Data(contentsOf: url)
            var changed = original
            changed.rating = invalid.rating
            changed.gpsLatitude = invalid.latitude
            changed.gpsLongitude = invalid.longitude

            #expect(throws: (any Error).self) {
                try ExifTool.writeCoreFields(url: url, fields: changed, original: original)
            }
            #expect(try Data(contentsOf: url) == bytesBefore)
        }
    }

    @Test("GPS-Grenzwerte sind gültig und unveränderte Fremdwerte blockieren andere Felder nicht")
    func validBoundariesAndUnchangedForeignValues() throws {
        for (latitude, longitude) in [
            ("-90", "-180"), ("0", "0"), ("90", "180"), ("", ""),
        ] {
            var fields = ImageCoreFields()
            fields.gpsLatitude = latitude
            fields.gpsLongitude = longitude
            #expect(throws: Never.self) {
                try ExifTool.requireValidCoreFields(fields)
            }
        }

        var foreign = ImageCoreFields()
        foreign.rating = 99
        foreign.gpsLatitude = "91"
        foreign.gpsLongitude = "181"
        var titleChange = foreign
        titleChange.title = "Nur dieses Feld ändert sich"
        #expect(throws: Never.self) {
            try ExifTool.requireValidCoreFields(titleChange, original: foreign)
        }
    }

    @Test("Archiv-Read-back scheitert vor dem atomaren Austausch")
    func archivedNormalizationLeavesOriginalUntouched() throws {
        let url = try Fixtures.workingCopy("cover.jpg")
        let original = try ExifTool.readCoreFields(url: url)
        let bytesBefore = try Data(contentsOf: url)
        let stampBefore = try #require(FileStamp.current(of: url))
        var target = original
        // exiftool speichert dieselbe Koordinate numerisch, liest sie aber als
        // "48.1"/"11.2" zurück. Ein Archiv verlangt den exakten Sollwert und
        // muss deshalb abbrechen, OHNE die normalisierte Datei einzuwechseln.
        target.gpsLatitude = "48.1000"
        target.gpsLongitude = "11.2000"

        #expect(throws: TagError.saveFailed(path: url.path)) {
            try ExifTool.writeCoreFields(
                url: url, fields: target, original: original,
                allowingArchivedValues: true)
        }
        #expect(try Data(contentsOf: url) == bytesBefore)
        #expect(FileStamp.current(of: url) == stampBefore)
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

    @Test("Roh-Text-Tags mehrerer Dateien in einem Aufruf (Kopier-Quellen)")
    func readRawStringTags() throws {
        let jpg = try Fixtures.workingCopy("cover.jpg")
        let png = try Fixtures.workingCopy("cover.png")
        let original = try ExifTool.readCoreFields(url: jpg)
        var edited = original
        edited.description = "Quelle fürs Umkopieren"
        try ExifTool.writeCoreFields(url: jpg, fields: edited, original: original)

        let raw = try ExifTool.readRawStringTags(urls: [jpg, png])
        #expect(raw.count == 2)
        let jpgTags = try #require(raw[jpg.path])
        // Der geschriebene Wert muss als "Gruppe:Tag" auffindbar sein
        #expect(jpgTags.contains { $0.key.contains(":") && $0.value == "Quelle fürs Umkopieren" })
        // Binärwerte (z.B. Thumbnails) dürfen nicht als Kopier-Quelle auftauchen
        #expect(!jpgTags.values.contains { $0.hasPrefix("(Binary data") })
    }

    @Test("Roh-Text-Tags sind auch über eine Verknüpfung auffindbar")
    func readRawStringTagsKeyedByGivenPath() throws {
        // exiftool bekommt den aufgelösten Pfad und meldet ihn als SourceFile
        // zurück. Fragt der Aufrufer mit SEINER URL nach — bei einem Symlink
        // also mit dem Verknüpfungspfad —, muss er sein Ergebnis trotzdem
        // finden; sonst bliebe `exif set --copy` über Verknüpfungen wirkungslos
        // und meldete "No changes".
        let jpg = try Fixtures.workingCopy("cover.jpg")
        let original = try ExifTool.readCoreFields(url: jpg)
        var edited = original
        edited.description = "Über eine Verknüpfung gelesen"
        try ExifTool.writeCoreFields(url: jpg, fields: edited, original: original)

        let link = jpg.deletingLastPathComponent().appendingPathComponent("verknuepfung.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: jpg)

        let raw = try ExifTool.readRawStringTags(urls: [link])
        let tags = try #require(raw[link.path])
        #expect(tags.contains { $0.value == "Über eine Verknüpfung gelesen" })
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

    @Test("Ersetzung zwischen exiftool-Read und Stempelprüfung wird erkannt")
    func replacementDuringSnapshotReadIsRejected() throws {
        let url = try Fixtures.workingCopy("cover.jpg")
        let replacement = try Fixtures.workingCopy("cover.png")
        let replacementBytes = try Data(contentsOf: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            _ = try ExifTool.readCoreFieldsSnapshot(url: url, afterRead: {
                try TestFiles.replaceAtomically(url, with: replacement)
            })
        }
        #expect(try Data(contentsOf: url) == replacementBytes)
    }

    // MARK: - Kamera-RAW und XMP-Sidecar

    /// Kopiert das TIFF-Fixture unter einer RAW-Endung ins Arbeitsverzeichnis.
    /// NEF/DNG sind TIFF-Container; exiftool erkennt die Datei als RAW.
    private func rawWorkingCopy(extension ext: String) throws -> URL {
        let tif = try Fixtures.workingCopy("cover.tif")
        let raw = tif.deletingPathExtension().appendingPathExtension(ext)
        try FileManager.default.moveItem(at: tif, to: raw)
        return raw
    }

    @Test("Schreibfähigkeit der Bildformate stimmt mit exiftool -listwf überein")
    func imageWritabilityMatchesExifTool() throws {
        let writable = try ExifTool.writableExtensions()
        #expect(writable.contains("jpg") && writable.contains("xmp"))
        // Nicht geraten: Was wir als „nur über Sidecar" führen, darf exiftool
        // nicht schreiben können — und umgekehrt muss jedes andere Bildformat
        // (samt RAW, das wir nur aus Prinzip nicht anfassen) in der Liste stehen.
        for ext in MediaFormats.imageEmbeddedReadOnly {
            #expect(!writable.contains(ext), "exiftool kann \(ext) inzwischen schreiben")
        }
        for ext in MediaFormats.image.subtracting(MediaFormats.imageEmbeddedReadOnly) {
            #expect(writable.contains(ext), "exiftool kann \(ext) nicht schreiben")
        }
    }

    @Test("Schreibziel: RAW, nicht schreibbare Formate und vorhandene Sidecar erzwingen die Sidecar")
    func writeDestinationRules() throws {
        let raw = try rawWorkingCopy(extension: "nef")
        let rawTarget = ExifTool.writeDestination(for: raw, preferSidecar: false)
        #expect(rawTarget.reason == .rawFormat)
        #expect(rawTarget.url == raw.deletingPathExtension().appendingPathExtension("xmp"))

        let bmp = try Fixtures.workingCopy("cover.bmp")
        #expect(ExifTool.writeDestination(for: bmp, preferSidecar: false).reason == .formatNotWritable)

        let jpg = try Fixtures.workingCopy("cover.jpg")
        #expect(ExifTool.writeDestination(for: jpg, preferSidecar: false).reason == .original)
        #expect(ExifTool.writeDestination(for: jpg, preferSidecar: true).reason == .setting)
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)
            .write(to: MediaFormats.sidecarURL(for: jpg))
        #expect(ExifTool.writeDestination(for: jpg, preferSidecar: false).reason == .existingSidecar)

        let xmp = MediaFormats.sidecarURL(for: jpg)
        let xmpTarget = ExifTool.writeDestination(for: xmp, preferSidecar: true)
        #expect(xmpTarget.reason == .original && xmpTarget.url == xmp)
    }

    @Test("RAW: Schreiben legt die Sidecar an und lässt die RAW-Datei byteweise unverändert")
    func rawWritesGoToSidecar() throws {
        let raw = try rawWorkingCopy(extension: "nef")
        let rawBytes = try Data(contentsOf: raw)
        let sidecar = MediaFormats.sidecarURL(for: raw)
        let snapshot = try ExifTool.readCoreFieldsSnapshot(url: raw)
        #expect(snapshot.value.sidecar == .absent)

        var edited = snapshot.value.fields
        edited.title = "RAW-Titel"
        edited.rating = 4
        edited.gpsLatitude = "50.9375"
        edited.gpsLongitude = "6.9603"
        // Kein Ziel angegeben: Die Regel im Core muss von sich aus zur
        // Sidecar greifen — sonst wäre ein Aufrufer ohne Sidecar-Wissen
        // eine Lücke in der RAW-Regel.
        try ExifTool.writeCoreFields(
            url: raw, fields: edited, original: snapshot.value.fields,
            expecting: snapshot.stamp, sidecar: snapshot.value.sidecar)

        #expect(try Data(contentsOf: raw) == rawBytes)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        let reading = try ExifTool.readCoreReading(url: raw)
        #expect(reading.fields.title == "RAW-Titel")
        #expect(reading.fields.rating == 4)
        #expect(reading.sidecarURL == sidecar)
        #expect(reading.sidecarFields == [.title, .rating, .gps])
        guard case .present = reading.sidecar else {
            Issue.record("Sidecar-Zustand nach dem Anlegen: \(reading.sidecar)")
            return
        }

        // Zweiter Lauf auf die nun vorhandene Sidecar (atomarer Austausch).
        var second = reading.fields
        second.description = "Zweiter Lauf"
        try ExifTool.writeCoreFields(
            url: raw, fields: second, original: reading.fields,
            sidecar: reading.sidecar)
        let after = try ExifTool.readCoreReading(url: raw)
        #expect(after.fields.description == "Zweiter Lauf")
        #expect(after.fields.title == "RAW-Titel")
        #expect(try Data(contentsOf: raw) == rawBytes)
        // Keine Temp-Reste neben der Sidecar
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: raw.deletingLastPathComponent().path)
            .filter { $0.contains(".tagx-") }
        #expect(leftovers.isEmpty, "Temp-Reste: \(leftovers)")
    }

    @Test("Sidecar-Werte überlagern eingebettete Werte feldweise")
    func sidecarOverlaysEmbeddedValuesPerField() throws {
        let jpg = try Fixtures.workingCopy("cover.jpg")
        let empty = try ExifTool.readCoreFields(url: jpg)
        var embedded = empty
        embedded.description = "eingebettet"
        embedded.creator = "Kamera"
        try ExifTool.writeCoreFields(url: jpg, fields: embedded, original: empty)

        // Sidecar über die Einstellung anlegen — nur mit einem Titel.
        var withTitle = embedded
        withTitle.title = "Sidecar-Titel"
        let setting = ExifTool.writeDestination(for: jpg, preferSidecar: true)
        try ExifTool.writeCoreFields(
            url: jpg, fields: withTitle, original: embedded, to: setting, sidecar: .absent)

        let reading = try ExifTool.readCoreReading(url: jpg)
        #expect(reading.fields.title == "Sidecar-Titel")
        #expect(reading.fields.description == "eingebettet")
        #expect(reading.fields.creator == "Kamera")
        #expect(reading.sidecarFields == [.title])

        // Ab jetzt landet jede Änderung in der Sidecar, auch ohne Einstellung:
        // sonst bliebe sie hinter dem überlagernden Sidecar-Wert unsichtbar.
        var creatorChange = reading.fields
        creatorChange.creator = "Neu"
        try ExifTool.writeCoreFields(
            url: jpg, fields: creatorChange, original: reading.fields, sidecar: reading.sidecar)
        let after = try ExifTool.readCoreReading(url: jpg)
        #expect(after.fields.creator == "Neu")
        #expect(after.sidecarFields == [.title, .creator])
        // Die Sidecar alleine gelesen kennt nur ihre eigenen Felder
        let alone = try ExifTool.readCoreReading(url: MediaFormats.sidecarURL(for: jpg))
        #expect(alone.fields.description.isEmpty && alone.sidecarURL == nil)
    }

    @Test(".xmp alleine: lesen und bearbeiten wie ein Bild ohne Pixel")
    func standaloneXMPRoundtrip() throws {
        let dir = try Fixtures.workingCopy("cover.jpg").deletingLastPathComponent()
        let xmp = dir.appendingPathComponent("notiz.xmp")
        // Eine leere XMP-Datei, wie sie ein anderes Programm hinterlassen
        // haben könnte; geöffnet wird immer eine vorhandene Datei.
        try Data("""
            <?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
            <x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF \
            xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\
            <rdf:Description rdf:about=''/></rdf:RDF></x:xmpmeta>
            <?xpacket end='w'?>
            """.utf8).write(to: xmp)
        var fields = ImageCoreFields()
        fields.title = "Nur XMP"
        fields.keywords = ["a", "b"]
        try ExifTool.writeCoreFields(url: xmp, fields: fields, original: ImageCoreFields())
        let first = try ExifTool.readCoreReading(url: xmp)
        #expect(first.fields.title == "Nur XMP")
        #expect(first.fields.keywords == ["a", "b"])
        #expect(first.sidecarURL == nil && first.sidecar == .absent)

        var edited = first.fields
        edited.rating = 2
        edited.keywords = []
        try ExifTool.writeCoreFields(url: xmp, fields: edited, original: first.fields)
        let second = try ExifTool.readCoreFields(url: xmp)
        #expect(second.rating == 2)
        #expect(second.keywords.isEmpty)
    }

    @Test("Fremd angelegte oder veränderte Sidecar gilt als Konflikt")
    func foreignSidecarChangesAreConflicts() throws {
        let raw = try rawWorkingCopy(extension: "arw")
        let sidecar = MediaFormats.sidecarURL(for: raw)
        let snapshot = try ExifTool.readCoreFieldsSnapshot(url: raw)
        var edited = snapshot.value.fields
        edited.title = "Konflikt"

        // Zwischen Lesen und Schreiben legt ein anderes Programm die Sidecar an.
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8).write(to: sidecar)
        let foreignBytes = try Data(contentsOf: sidecar)
        #expect(throws: TagError.fileChangedOnDisk(path: sidecar.path)) {
            try ExifTool.writeCoreFields(
                url: raw, fields: edited, original: snapshot.value.fields,
                expecting: snapshot.stamp, sidecar: snapshot.value.sidecar)
        }
        #expect(try Data(contentsOf: sidecar) == foreignBytes)

        // Umgekehrt: Sidecar war da, wurde inzwischen ersetzt.
        let known = try ExifTool.readCoreFieldsSnapshot(url: raw)
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'></x:xmpmeta>".utf8).write(to: sidecar)
        #expect(throws: TagError.fileChangedOnDisk(path: sidecar.path)) {
            try ExifTool.writeCoreFields(
                url: raw, fields: edited, original: known.value.fields,
                expecting: known.stamp, sidecar: known.value.sidecar)
        }
    }

    @Test("Exif-No-op bestätigt keinen inzwischen ersetzten Pfad")
    func exifNoopRejectsStaleSnapshot() throws {
        let url = try Fixtures.workingCopy("cover.jpg")
        let snapshot = try ExifTool.readCoreFieldsSnapshot(url: url)
        let replacement = try Fixtures.workingCopy("cover.jpg")
        try TestFiles.replaceAtomically(url, with: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            try ExifTool.writeCoreFields(
                url: url, fields: snapshot.value.fields, original: snapshot.value.fields,
                expecting: snapshot.stamp)
        }
    }
}
