# Wissens-Index tag_explosion

Eine Datei pro Problem; konsultieren, wenn der Trigger zutrifft.

- [dateisicherheit-schreibwege.md](dateisicherheit-schreibwege.md) — Bei jedem
  Schreibweg und beim abgesicherten Modus: atomarer Rahmen, Papierkorb-
  Sicherung, `URL.resourceValues`-Cache-Falle, Platz- und Pfad-Regeln.
- [taglib-shim.md](taglib-shim.md) — Bei Arbeit am CTagShim/TagLib-Upgrade:
  Encoding-Default, C-API-Grenzen, PropertyMap-Verhalten, Format-Toleranzen.
- [mediainfo-exiftool-wrapper.md](mediainfo-exiftool-wrapper.md) — Bei kaputten
  Umlauten in Reports oder exiftool-Schreibfehlern: Surrogate-Escapes, MWG-Modul.
- [gui-selbsttests.md](gui-selbsttests.md) — Bei GUI-/AX-Tests der App:
  was funktioniert (Maus, AX-Setzen), was nicht (synthetische Tastatur).
- [epub-opf-struktur.md](epub-opf-struktur.md) — Beim Schreiben von
  EPUB-Metadaten: Der `unique-identifier` des Pakets hängt meist am ISBN-Knoten;
  Identifier, refines und neue XML-IDs müssen konsistent nachgeführt werden.
- [ebook-meta-calibre-quirks.md](ebook-meta-calibre-quirks.md) — Beim
  E-Book-Backend mobi/azw3/fb2: azw3 verliert Serien, Datums-/Index-Semantik,
  nicht sicher löschbare Cover und LC_ALL=C.
- [e-rechnung-anzeige.md](e-rechnung-anzeige.md) — Bei Arbeit an EInvoiceCore,
  `tagx invoice` oder der Rechnungsansicht: Profil-URNs (BT-24), ambige
  BT-Zuordnungen (Nachlass/Zuschlag, VA/FC, BT-110/111), CGPDF-Extraktion,
  XMP-Präfix-Falle.
