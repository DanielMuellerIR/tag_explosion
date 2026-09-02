// Die Bewertungs-Picker müssen jeden Modellwert sichtbar abbilden: kein Tag,
// „abgelehnt" (−1), die Sterne 0…5 und tolerierte Fremdwerte. Vorher fehlten
// −1 und Fremdwerte in beiden Pickern, die Auswahl blieb dann leer
// (Review-Fund 2026-08-22).
import Foundation
import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Bewertungs-Picker")
struct RatingPickerTests {

    // MARK: - Einzel-Editor

    @Test("Standardeinträge: keine, abgelehnt, 0…5 — in dieser Reihenfolge")
    func singleStandardOptions() {
        let options = RatingPicker.options(current: nil)
        #expect(options.map(\.value) == [nil, -1, 0, 1, 2, 3, 4, 5])
        #expect(options.map(\.label) == ["keine", "abgelehnt", "0", "★", "★★", "★★★", "★★★★", "★★★★★"])
    }

    @Test("Jeder Standardwert — auch −1 — findet seinen Eintrag ohne Zusatz",
          arguments: [Int?.none, -1, 0, 3, 5])
    func singleStandardValuesNeedNoExtraEntry(current: Int?) {
        let options = RatingPicker.options(current: current)
        #expect(options.count == 8)
        #expect(options.contains { $0.value == current })
    }

    @Test("Ein Fremdwert wird als Bestandswert sichtbar angehängt, nicht umgedeutet",
          arguments: [7, -3, 99])
    func singleForeignValueIsShownAsIs(current: Int) {
        let options = RatingPicker.options(current: current)
        #expect(options.count == 9)
        #expect(options.last?.value == current)
        #expect(options.last?.label == "\(current) (Bestand)")
        // Die Standardwerte bleiben unverändert davor.
        #expect(options.dropLast().map(\.value) == [nil, -1, 0, 1, 2, 3, 4, 5])
    }

    @Test("Picker-Auswahl am Eintrag: −1 bleibt −1, nil bleibt nil")
    @MainActor
    func singleEntryKeepsRejectedAndAbsent() {
        let rejected = FileEntry(url: URL(fileURLWithPath: "/tmp/rejected.jpg"),
                                 loaded: .image(ImageCoreReading(fields: ImageCoreFields(rating: -1))))
        #expect(RatingPicker.options(current: rejected.imageFields.rating)
            .contains { $0.value == rejected.imageFields.rating })
        // Auswahl „keine" löscht das Tag; danach ist der Eintrag dirty.
        rejected.imageFields.rating = nil
        #expect(rejected.isDirty)
        #expect(RatingPicker.options(current: nil).first?.value == nil)
    }

    // MARK: - Batch-Editor

    @Test("Gemeinsamer Zustand: leer, alle ohne Tag, alle gleich, gemischt")
    func batchChoiceMapping() {
        #expect(RatingChoice.choice(for: []) == .none)
        #expect(RatingChoice.choice(for: [nil, nil]) == .none)
        #expect(RatingChoice.choice(for: [3, 3, 3]) == .value(3))
        #expect(RatingChoice.choice(for: [-1, -1]) == .value(-1))
        #expect(RatingChoice.choice(for: [7, 7]) == .value(7))
        #expect(RatingChoice.choice(for: [3, 4]) == .mixed)
        #expect(RatingChoice.choice(for: [nil, 0]) == .mixed)
        #expect(RatingChoice.choice(for: [nil, -1]) == .mixed)
    }

    @Test("Batch-Einträge enthalten abgelehnt; ein gemeinsamer Fremdwert wird angehängt")
    func batchOptions() {
        let standard = RatingChoice.options(current: .none)
        #expect(standard == [.mixed, .none, .value(-1), .value(0), .value(1),
                             .value(2), .value(3), .value(4), .value(5)])
        #expect(RatingChoice.options(current: .value(-1)) == standard)
        #expect(RatingChoice.options(current: .mixed) == standard)
        let foreign = RatingChoice.options(current: .value(7))
        #expect(foreign == standard + [.value(7)])
        #expect(RatingChoice.value(7).label == "7 (Bestand)")
        #expect(RatingChoice.value(-1).label == "abgelehnt")
        #expect(RatingChoice.mixed.label == "— verschieden —")
    }

    @Test("Was die Auswahl schreibt: verschieden nichts, keine löscht, Wert setzt")
    func batchApply() {
        #expect(RatingChoice.mixed.ratingToApply == nil)
        #expect(RatingChoice.none.ratingToApply == .some(nil))
        #expect(RatingChoice.value(-1).ratingToApply == .some(-1))
        #expect(RatingChoice.value(4).ratingToApply == .some(4))
    }

    @Test("Gemischte Einträge: −1 setzen trifft alle, verschieden lässt alles stehen")
    @MainActor
    func batchBindingOnEntries() {
        let entries = [
            FileEntry(url: URL(fileURLWithPath: "/tmp/a.jpg"), loaded: .image(ImageCoreReading(fields: ImageCoreFields(rating: nil)))),
            FileEntry(url: URL(fileURLWithPath: "/tmp/b.jpg"), loaded: .image(ImageCoreReading(fields: ImageCoreFields(rating: 5)))),
            FileEntry(url: URL(fileURLWithPath: "/tmp/c.jpg"), loaded: .image(ImageCoreReading(fields: ImageCoreFields(rating: -1)))),
        ]
        #expect(RatingChoice.choice(for: entries.map(\.imageFields.rating)) == .mixed)
        // Dieselbe Logik wie im Binding-Setter des Batch-Editors.
        func apply(_ choice: RatingChoice) {
            guard let rating = choice.ratingToApply else { return }
            for entry in entries { entry.imageFields.rating = rating }
        }
        apply(.mixed)
        #expect(entries.map(\.imageFields.rating) == [nil, 5, -1])
        #expect(entries.map(\.isDirty) == [false, false, false])
        apply(.value(-1))
        #expect(entries.map(\.imageFields.rating) == [-1, -1, -1])
        #expect(RatingChoice.choice(for: entries.map(\.imageFields.rating)) == .value(-1))
        #expect(entries.map(\.isDirty) == [true, true, false])
        apply(.none)
        #expect(entries.map(\.imageFields.rating) == [nil, nil, nil])
        #expect(RatingChoice.choice(for: entries.map(\.imageFields.rating)) == .none)
    }
}
