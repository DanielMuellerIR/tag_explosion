# Dritt-Komponenten

Eigener Code steht unter MIT (siehe [LICENSE](LICENSE)). Dritt-Komponenten
behalten ihre eigene Lizenz:

| Komponente | Lizenz | Einbindung |
|------------|--------|-----------|
| [TagLib](https://taglib.org) | LGPL-2.1 **oder** MPL-1.1 | Dynamisch gelinkt; im Release-Build werden `libtag`/`libtag_c` **unverändert** ins App-Bundle kopiert (Contents/Frameworks). Quellcode: taglib.org bzw. Homebrew-Formel `taglib`. |
| [MediaInfo](https://mediaarea.net/MediaInfo) | BSD-2-Clause | Nicht gebündelt — wird als externes Programm aufgerufen, falls installiert. |
| [ExifTool](https://exiftool.org) | Perl Artistic License | Nicht gebündelt — wird als externes Programm aufgerufen, falls installiert. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | Statisch im CLI-Tool `tagx`. |

Das App-Icon wurde mit MiniMax `image-01` generiert; die Nutzungsrechte an
generierten Inhalten liegen laut MiniMax Platform ToS beim Ersteller.
