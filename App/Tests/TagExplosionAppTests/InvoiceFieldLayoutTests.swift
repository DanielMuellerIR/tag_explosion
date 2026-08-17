// Spaltenaufteilung der E-Rechnungs-Feldliste. Die feste 380-pt-Spalte ließ
// dem Inhalt bei Standard-Fenstergröße zu wenig Platz — Werte brachen mitten
// im Wort um. Diese Regeln halten den Inhalt breiter als die Term-Spalte.
import Foundation
import Testing
@testable import TagExplosionApp

@Suite("E-Rechnung Spaltenbreite")
struct InvoiceFieldLayoutTests {

    /// Was dem Inhalt (Elementname + Wert) bei einer Fensterbreite bleibt.
    private func contentWidth(for container: CGFloat) -> CGFloat {
        let usable = min(container, InvoiceFieldLayout.maxContentWidth)
            - 2 * InvoiceFieldLayout.padding
        return usable - InvoiceFieldLayout.termColumnWidth(containerWidth: container)
            - InvoiceFieldLayout.columnSpacing
    }

    @Test("Bei Mindestfensterbreite bleibt der Inhalt breiter als die BT-Spalte")
    func contentKeepsTheLargerShare() {
        // 900 pt Fenster mit eingeblendeter Seitenleiste (280) — der engste
        // Fall, den die App zulässt.
        let narrow: CGFloat = 900 - 280
        #expect(contentWidth(for: narrow) > InvoiceFieldLayout.termColumnWidth(containerWidth: narrow))
        // Ohne Seitenleiste (Grundeinstellung bei einer Datei) ist es deutlich mehr.
        #expect(contentWidth(for: 900) > contentWidth(for: narrow))
    }

    @Test("Die BT-Spalte wächst mit, bleibt aber gedeckelt")
    func termColumnGrowsAndIsCapped() {
        let narrow = InvoiceFieldLayout.termColumnWidth(containerWidth: 620)
        let wide = InvoiceFieldLayout.termColumnWidth(containerWidth: 1100)
        #expect(narrow < wide)
        #expect(wide <= 380)
        // Über der Höchstbreite ändert sich nichts mehr: Die Spalte wandert
        // dann nicht weiter nach rechts.
        #expect(InvoiceFieldLayout.termColumnWidth(containerWidth: 4000)
            == InvoiceFieldLayout.termColumnWidth(containerWidth: InvoiceFieldLayout.maxContentWidth))
    }

    @Test("Auch bei absurd schmalem Fenster bleibt die Spalte benutzbar")
    func termColumnHasAFloor() {
        #expect(InvoiceFieldLayout.termColumnWidth(containerWidth: 0) == 150)
        #expect(InvoiceFieldLayout.termColumnWidth(containerWidth: 200) == 150)
    }
}
