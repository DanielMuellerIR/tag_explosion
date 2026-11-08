#!/usr/bin/env python3
"""Linux-Texte aus dem gemeinsamen String-Catalog ableiten."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
catalog = json.loads((root / 'App/Sources/TagExplosionApp/Resources/Localizable.xcstrings').read_text())
translations = {}
for key, item in catalog['strings'].items():
    unit = item.get('localizations', {}).get('en', {}).get('stringUnit', {})
    if 'value' in unit:
        translations[key] = unit['value']
labels = {
    'TITLE': 'Titel', 'ARTIST': 'Künstler', 'ALBUM': 'Album', 'ALBUMARTIST': 'Albumkünstler',
    'GENRE': 'Genre', 'DATE': 'Jahr', 'TRACKNUMBER': 'Track', 'DISCNUMBER': 'CD',
    'COMPOSER': 'Komponist', 'COMMENT': 'Kommentar', 'LYRICS': 'Liedtext',
    'title': 'Titel', 'authors': 'Autoren', 'author': 'Autor', 'artist': 'Künstler', 'album': 'Album',
    'subject': 'Betreff', 'description': 'Beschreibung', 'keywords': 'Schlagwörter',
    'creator': 'Ersteller', 'copyright': 'Copyright', 'dateTimeOriginal': 'Aufnahmedatum',
    'rating': 'Bewertung', 'gpsLatitude': 'Breitengrad', 'gpsLongitude': 'Längengrad',
    'series': 'Serie', 'seriesIndex': 'Serienindex', 'isbn': 'ISBN', 'publisher': 'Verlag',
    'language': 'Sprache', 'date': 'Datum', 'subjects': 'Schlagwörter', 'created': 'Erstellt',
    'modified': 'Geändert', 'category': 'Kategorie', 'custom': 'Eigene Felder',
    'lyricsLanguage': 'Sprache der Lyrics', 'syncedLyrics': 'Synchronisierte Liedtexte',
    'milliseconds': 'Zeit (ms)', 'text': 'Text', 'startMilliseconds': 'Beginn (ms)',
    'endMilliseconds': 'Ende (ms)', 'performer': 'Interpret', 'entries': 'Einträge',
    'year': 'Jahr', 'genre': 'Genre', 'key': 'Feldname', 'value': 'Wert',
    'invoiceNumber': 'Rechnungsnummer', 'issueDate': 'Rechnungsdatum', 'sellerName': 'Verkäufer', 'buyerName': 'Käufer', 'currency': 'Währung', 'payableAmount': 'Zahlbetrag',
    'code': 'Code', 'message': 'Meldung', 'term': 'Feld', 'status': 'Status', 'path': 'Datei', 'name': 'Name', 'severity': 'Schweregrad', 'location': 'Fundstelle', 'oldValue': 'Bisher', 'newValue': 'Neu', 'trackIndex': 'Zuordnung',
    'originalTitle': 'Originaltitel', 'sortTitle': 'Sortiertitel', 'showTitle': 'Serientitel', 'premiered': 'Premiere', 'tagline': 'Tagline', 'genres': 'Genres', 'tags': 'Tags', 'credits': 'Drehbuch', 'userRating': 'Eigene Bewertung', 'runtime': 'Laufzeit', 'season': 'Staffel', 'episode': 'Folge', 'mpaa': 'Altersfreigabe',
    'plot': 'Handlung', 'outline': 'Kurzbeschreibung', 'directors': 'Regie', 'actors': 'Darsteller',
}
output = '// Generiert durch scripts/linux-translations.py aus dem gemeinsamen String-Catalog.\n'
output += 'export const labels = ' + json.dumps(labels, ensure_ascii=False, indent=2) + ';\n'
output += 'const english = ' + json.dumps(translations, ensure_ascii=False, indent=2) + ';\n'
output += "let language = navigator.language;\nexport function setLanguage(value) { language = value; }\nexport function translate(text) { return language.toLowerCase().startsWith('de') ? text : (english[text] || text); }\n"
(root / 'Linux/frontend/translations.js').write_text(output)

output = "// Generiert aus dem gemeinsamen String-Catalog; nicht von Hand bearbeiten.\n#if os(Linux)\nenum ApplicationTranslations {\n    static let english: [String: String] = [\n"
output += ",\n".join("        " + json.dumps(key, ensure_ascii=False) + ": " + json.dumps(value, ensure_ascii=False) for key, value in translations.items())
output += "\n    ]\n}\n#endif\n"
(root / 'Sources/TagExplosionApplication/ApplicationTranslations.swift').write_text(output)
