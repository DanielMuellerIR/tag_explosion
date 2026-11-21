import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

extension TagArchiveTests {
    @Test("Fachfremde Bildwerte bleiben strukturell archivierbar")
    func foreignImageValuesRemainStructurallyValid() throws {
        // exiftool liest auch fachlich unmögliche Werte (Rating 6, GPS 91/181)
        // aus bestehenden Bildern. Ein Backup muss genau diesen Bestand
        // sichern können — sonst bricht das Auto-Backup jeden Batch-Save ab.
        // Ob ein Wert ins ZIEL geschrieben werden darf, prüft erst der Import
        // je Eintrag gegen den dort gelesenen Zustand.
        var ratingHigh = ImageCoreFields()
        ratingHigh.rating = 6
        var ratingLow = ImageCoreFields()
        ratingLow.rating = -2
        var gpsOutOfRange = ImageCoreFields()
        gpsOutOfRange.gpsLatitude = "91"
        gpsOutOfRange.gpsLongitude = "181"
        var gpsNotANumber = ImageCoreFields()
        gpsNotANumber.gpsLatitude = "keine Zahl"
        gpsNotANumber.gpsLongitude = "0"
        for fields in [ratingHigh, ratingLow, gpsOutOfRange, gpsNotANumber] {
            let archive = TagArchive(created: "2026-08-02T00:00:00Z", files: [
                .init(path: "cover.jpg", kind: .image, image: fields),
            ])
            #expect(throws: Never.self) { try TagArchiveIO.validate(archive) }
        }
    }

    @Test("Bestand mit fachfremden Bildwerten ist exportier- und wiederherstellbar")
    func foreignImageValuesStayExportable() throws {
        // Genau der Auto-Backup-Fall: Ein Bild trägt ein von exiftool
        // gelesenes, fachfremdes Rating. Der Export (== Auto-Backup vor einem
        // Batch-Save) darf daran nicht scheitern, und der unveränderte
        // Bestand muss als No-op wiederherstellbar bleiben.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=6", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 6)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)
        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)
        #expect(report.unchanged == ["cover.jpg"])
        #expect(report.failures.isEmpty)
    }

    @Test("Ein gesicherter Bestandswert kommt auch nach einer Änderung zurück")
    func archivedForeignImageValueRestoresAfterChange() throws {
        // Der Kern des Restore-Vertrags (Review-Fund 2026-08-17): Rating 6
        // exportieren, das Ziel danach auf 5 ändern, wieder auf 6 importieren.
        // Vorher lehnte genau dieser Import ab, weil er die Wertebereiche der
        // Oberfläche auch auf archivierte Bestandswerte anwandte — ein
        // erfolgreich erzeugtes Auto-Backup war damit nicht wiederherstellbar.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=6", image.path])

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        // Ziel danach auf einen gültigen Wert ändern.
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=5", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 5)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.failures.isEmpty)
        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == 6)
    }

    @Test("Ein gesichertes negatives Bestands-Rating kommt exakt zurück")
    func archivedNegativeRatingRestoresExactly() throws {
        // Derselbe Vertrag nach unten (Review-Fund 2026-08-18): Leerwert ist
        // ausschließlich -1. Ein gesichertes -2 bildete der Schreibweg vorher
        // auf „Rating-Tag löschen" ab; die Datei trug danach -1, und der
        // Read-back meldete den Fehlschlag erst NACH dem atomaren Austausch.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=-2", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == -2)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        // Zwischenzeitliche Änderung auf einen normalen Wert.
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=3", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 3)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.failures.isEmpty)
        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == -2)
    }

    @Test("Ein gesichertes Rating -1 wird zurueckgeschrieben, nicht geloescht")
    func archivedRejectedRatingRestoresExactly() throws {
        // -1 ist der von Adobe dokumentierte Wert fuer „abgelehnt" und wird von
        // Bridge und Lightroom wirklich geschrieben. Solange -1 zugleich der
        // Leerwert war, loeschte der Restore genau dieses Tag — und der
        // Read-back konnte den Fehler nicht sehen, weil er das geloeschte Tag
        // wieder als -1 las.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=-1", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == -1)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=3", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 3)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.failures.isEmpty)
        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == -1)
    }

    @Test("Ohne Rating-Tag bleibt das Feld leer und der Restore loescht es wieder")
    func missingRatingStaysAbsent() throws {
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        #expect(try ExifTool.readCoreFields(url: image).rating == nil)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=4", image.path])

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == nil)
    }

    @Test("Im alten Schema 1 bleibt -1 der Leerwert")
    func legacySchemaTreatsMinusOneAsAbsent() throws {
        // Schema 1 konnte „kein Tag" und „Tag mit -1" nicht unterscheiden und
        // schrieb fuer beides -1. Ein solcher Bestand darf beim Import kein
        // -1-Tag in eine Datei schreiben, die vorher keines hatte.
        var fields = ImageCoreFields()
        fields.rating = -1
        let legacy = TagArchive(version: 1, created: "2026-07-19T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: fields),
        ])

        let normalized = TagArchiveIO.normalizingLegacyValues(legacy)
        #expect(normalized.files[0].image?.rating == nil)

        // Ein Archiv im heutigen Schema behaelt die -1 dagegen.
        let current = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: fields),
        ])
        #expect(TagArchiveIO.normalizingLegacyValues(current).files[0].image?.rating == -1)
    }

    @Test("Technisch unschreibbare Archivwerte scheitern je Eintrag — Dry-run und Import gleich")
    func unwritableImageValuesFailConsistently() throws {
        // Die Wertebereiche gelten beim Restore nicht mehr, die TECHNISCHEN
        // Schranken schon: Eine halbe GPS-Koordinate kann exiftool nicht
        // sinnvoll schreiben. Der Fehler muss im Dry-run genauso erscheinen wie
        // im echten Lauf, und die Zieldatei bleibt unangetastet (insbesondere
        // entsteht keine Papierkorb-Sicherung vor dem Fehler).
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        var target = try ExifTool.readCoreFields(url: image)
        target.gpsLatitude = "48.1"
        target.gpsLongitude = ""          // unvollständiges Paar
        let archive = TagArchive(created: "2026-08-16T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: target),
        ])

        let dry = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: true)
        #expect(dry.failures.map(\.path) == ["cover.jpg"])
        let bytesBefore = try Data(contentsOf: image)
        let real = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(real.failures.map(\.path) == ["cover.jpg"])
        #expect(try Data(contentsOf: image) == bytesBefore)
    }

    @Test("Normalisierte Bildwerte scheitern im Dry-run und vor der Sicherung")
    func normalizedImageValuesFailBeforeBackup() throws {
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let bytesBefore = try Data(contentsOf: image)
        var target = try ExifTool.readCoreFields(url: image)
        // exiftool speichert diese Dezimalzahlen, liest sie aber ohne die
        // nachgestellten Nullen zurück. Das Archiv verspricht exakte Werte.
        target.gpsLatitude = "48.1000"
        target.gpsLongitude = "11.2000"
        let archive = TagArchive(created: "2026-08-30T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: target),
        ])
        var backupCalls = 0
        let backUp: (URL) throws -> Void = { _ in backupCalls += 1 }

        let dry = try TagArchiveIO.apply(
            archive, relativeTo: dir, dryRun: true,
            afterValidation: {}, backUp: backUp)
        #expect(dry.failures.map(\.path) == ["cover.jpg"])
        #expect(backupCalls == 0)

        let real = try TagArchiveIO.apply(
            archive, relativeTo: dir, dryRun: false,
            afterValidation: {}, backUp: backUp)
        #expect(real == dry)
        #expect(backupCalls == 0)
        #expect(try Data(contentsOf: image) == bytesBefore)
    }

    @Test("Die Oberfläche lehnt eine echte Änderung auf fachfremde Werte weiter ab")
    func uiStillRejectsOutOfRangeChanges() throws {
        // Gegenprobe zur Trennung: Der Restore-Pfad ist gelockert, der
        // Bearbeitungspfad NICHT.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let current = try ExifTool.readCoreFields(url: image)
        var target = current
        target.rating = 6

        #expect(throws: (any Error).self) {
            try ExifTool.requireValidCoreFields(target, original: current)
        }
        #expect(throws: Never.self) {
            try ExifTool.requireWritableCoreFields(target, original: current)
        }
    }
}
