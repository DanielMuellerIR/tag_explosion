// CTagShim — schlanke C-Schnittstelle über die TagLib-C++-API (MIT-lizenziert).
// Konventionen:
//  - Alle Strings sind UTF-8, heap-allokiert und gehören dem Aufrufer nach
//    Rückgabe (Freigabe über die passende tx_free_*-Funktion).
//  - Rückgabewert int: 1 = Erfolg, 0 = Fehler (sofern nicht anders vermerkt).
//  - Mehrwertige Tag-Felder werden als wiederholte Key/Value-Paare abgebildet.
#ifndef CTAGSHIM_H
#define CTAGSHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opakes Handle auf eine geöffnete Mediendatei.
typedef struct tx_file tx_file;

// Öffnet eine Datei (Pfad UTF-8). NULL, wenn TagLib das Format nicht lesen kann.
tx_file* tx_open(const char* path);

// Schließt das Handle und gibt alle internen Ressourcen frei.
void tx_close(tx_file* f);

// 1, wenn die Datei nur lesbar geöffnet werden konnte.
int tx_is_readonly(tx_file* f);

// Schreibt alle über tx_set_* gemachten Änderungen in die Datei. 1 = Erfolg.
int tx_save(tx_file* f);

// ---- Tag-Properties (Textfelder) ------------------------------------------

typedef struct {
    char* key;    // normalisierter Schlüssel, z.B. "ARTIST", "ALBUM", "TRACKNUMBER"
    char* value;  // ein Wert; mehrwertige Felder erscheinen als mehrere Einträge
} tx_prop;

// Liefert alle Properties (sortiert nach Schlüssel). out_count = Anzahl.
// Rückgabe NULL bei 0 Einträgen oder Fehler (out_count unterscheidet: 0 bzw. -1).
tx_prop* tx_get_properties(tx_file* f, int32_t* out_count);
void tx_free_properties(tx_prop* props, int32_t count);

// Ersetzt die komplette Property-Map durch die übergebenen Paare.
// Rückgabe: Anzahl der vom Format abgelehnten Properties (0 = alles übernommen),
// -1 bei Fehler. Erst tx_save() macht die Änderung persistent.
int32_t tx_set_properties(tx_file* f, const tx_prop* props, int32_t count);

// ---- Bilder (Cover etc.) ---------------------------------------------------

typedef struct {
    uint8_t* data;
    int32_t size;
    char* mime;          // MIME-Type, kann leer sein
    char* picture_type;  // z.B. "Front Cover"; leer = unbekannt
    char* description;   // Freitext, kann leer sein
} tx_picture;

tx_picture* tx_get_pictures(tx_file* f, int32_t* out_count);
void tx_free_pictures(tx_picture* pics, int32_t count);

// Ersetzt alle eingebetteten Bilder. Erst tx_save() macht es persistent.
int tx_set_pictures(tx_file* f, const tx_picture* pics, int32_t count);

// ---- Audio-Eigenschaften (read-only) ---------------------------------------

typedef struct {
    int32_t length_ms;
    int32_t bitrate_kbps;
    int32_t sample_rate_hz;
    int32_t channels;
} tx_audio_properties;

// 1 = Werte gefüllt, 0 = keine Audio-Eigenschaften verfügbar.
int tx_get_audio_properties(tx_file* f, tx_audio_properties* out);

// ---- Kapitel (Hörbücher, Podcasts) -----------------------------------------
//
// Getragen werden Kapitel von drei Containern:
//  - MP3: ID3v2 CHAP-Frames (Start/Ende in ms, Titel als eingebettetes TIT2)
//    plus ein CTOC-Frame als Top-Level-Inhaltsverzeichnis;
//  - MP4/M4A/M4B: Nero-Kapitel (`chpl`-Atom) und QuickTime-Kapitelspur;
//    gelesen wird die QuickTime-Spur, hilfsweise `chpl`, geschrieben werden
//    beide. MP4 kennt nur Startzeiten; end_ms ist beim Lesen deshalb -1.
//  - Matroska/WebM: `Chapters`-Element; gelesen wird die Standard-Edition
//    (sonst die erste), geschrieben genau eine Standard-Edition.
// Alle anderen Formate melden 0 bei tx_chapters_supported().

typedef struct {
    char* title;        // UTF-8; Eigentum des Aufrufers nach tx_get_chapters
    int64_t start_ms;   // Beginn in Millisekunden
    int64_t end_ms;     // Ende in Millisekunden; -1 = vom Format nicht geliefert
} tx_chapter;

// 1, wenn das Format der Datei Kapitel lesen UND schreiben kann, sonst 0.
int tx_chapters_supported(tx_file* f);

// Liefert die Kapitel in Abspielreihenfolge. out_count = Anzahl; NULL bei 0
// Einträgen oder Fehler (out_count unterscheidet: 0 bzw. -1). Das Array und
// alle Titel gehören danach dem Aufrufer: mit tx_free_chapters freigeben.
tx_chapter* tx_get_chapters(tx_file* f, int32_t* out_count);
void tx_free_chapters(tx_chapter* chapters, int32_t count);

// Ersetzt alle Kapitel der Datei durch die übergebenen (count 0 = alle
// entfernen). Der Shim kopiert die Daten; die Puffer des Aufrufers dürfen
// nach der Rückkehr freigegeben werden. 1 = Erfolg, 0 = Fehler oder Format
// ohne Kapitel. Erst tx_save() macht die Änderung persistent.
int tx_set_chapters(tx_file* f, const tx_chapter* chapters, int32_t count);

// ---- Lyrics und feste Felder außerhalb der PropertyMap ---------------------
//
// Unsynchronisierte Lyrics laufen als Property "LYRICS" über tx_get_/
// tx_set_properties. Was die PropertyMap nicht abbildet, kommt hier:
//  - die Sprache des ID3v2-USLT-Frames (ISO 639-2, drei Buchstaben),
//  - synchronisierte Lyrics (ID3v2 SYLT: Zeitstempel in ms + Text),
//  - Podcast-Felder ohne PropertyMap-Schlüssel: ID3v2-Textframes wie TKWD/
//    TVSN/TVEP, das PCST-Flag, MP4-Atome wie keyw/ldes und das pcst-Flag.
// ID3v2-Träger sind MP3/MP2, WAV, AIFF und DSF; MP4-Atome gelten für alle
// MP4-Container (m4a, m4b, mp4, m4v, 3gp …).

typedef struct {
    char* text;         // UTF-8; Eigentum des Aufrufers nach tx_get_synced_lyrics
    int64_t time_ms;    // Zeitpunkt in Millisekunden ab Dateianfang
} tx_synced_line;

// 1, wenn die Datei einen ID3v2-Tag tragen kann (und damit SYLT/USLT-Sprache).
int tx_id3v2_supported(tx_file* f);

// Sprache des ersten USLT-Frames (drei Buchstaben, z.B. "deu"; "XXX" =
// unbekannt). NULL, wenn kein USLT vorhanden ist oder das Format kein ID3v2
// kennt. Aufrufer gibt mit free() frei.
char* tx_get_lyrics_language(tx_file* f);

// Setzt die Sprache aller USLT-Frames. Ohne USLT-Frame passiert nichts (1).
// 0 = Format ohne ID3v2 oder ungültige Sprache (nicht genau drei Zeichen).
// Erst tx_save() macht die Änderung persistent.
int tx_set_lyrics_language(tx_file* f, const char* language);

// Zeilen des ersten SYLT-Frames mit Millisekunden-Zeitstempeln, nach Zeit
// sortiert. out_count = Anzahl; NULL bei 0 Einträgen oder Fehler (out_count
// unterscheidet: 0 bzw. -1). out_language (optional) erhält die Sprache des
// Frames (Aufrufer gibt frei) oder NULL. Array und Texte mit
// tx_free_synced_lyrics freigeben.
tx_synced_line* tx_get_synced_lyrics(tx_file* f, int32_t* out_count, char** out_language);
void tx_free_synced_lyrics(tx_synced_line* lines, int32_t count);

// Ersetzt alle SYLT-Frames durch genau einen mit den übergebenen Zeilen
// (count 0 = alle entfernen). language: drei Buchstaben oder NULL ("XXX").
// Der Shim kopiert die Daten. 1 = Erfolg, 0 = Fehler oder Format ohne ID3v2.
int tx_set_synced_lyrics(tx_file* f, const tx_synced_line* lines, int32_t count,
                         const char* language);

// Feld außerhalb der PropertyMap: id3_frame ist eine ID3v2-Frame-ID (vier
// Zeichen, z.B. "TKWD"; "PCST" = Podcast-Flag), mp4_atom ein MP4-Atomname
// (z.B. "keyw"; "pcst" = Podcast-Flag). Leer/NULL = für dieses Format kein
// Speicherort. Flags liefern "1", wenn gesetzt.
// 1, wenn das Format der Datei einen der beiden Speicherorte hat.
int tx_native_field_supported(tx_file* f, const char* id3_frame, const char* mp4_atom);
// Wert (UTF-8, Aufrufer gibt mit free() frei) oder NULL, wenn nicht vorhanden.
char* tx_get_native_field(tx_file* f, const char* id3_frame, const char* mp4_atom);
// Setzt den Wert; leer/NULL entfernt das Feld. 1 = Erfolg, 0 = Format ohne
// Speicherort oder Fehler. Erst tx_save() macht die Änderung persistent.
int tx_set_native_field(tx_file* f, const char* id3_frame, const char* mp4_atom,
                        const char* value);

// ---- Sonstiges --------------------------------------------------------------

// TagLib-Versionsstring der gelinkten Bibliothek, z.B. "2.3.0". Statisch, nicht freigeben.
const char* tx_taglib_version(void);

#ifdef __cplusplus
}
#endif

#endif // CTAGSHIM_H
