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

// ---- Sonstiges --------------------------------------------------------------

// TagLib-Versionsstring der gelinkten Bibliothek, z.B. "2.3.0". Statisch, nicht freigeben.
const char* tx_taglib_version(void);

#ifdef __cplusplus
}
#endif

#endif // CTAGSHIM_H
