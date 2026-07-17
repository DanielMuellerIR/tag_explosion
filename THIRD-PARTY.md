# Dritt-Komponenten

Eigener Code steht unter MIT (siehe [LICENSE](LICENSE)). Dritt-Komponenten
behalten ihre eigene Lizenz:

| Komponente | Lizenz | Einbindung |
|------------|--------|-----------|
| [TagLib](https://taglib.org) | LGPL-2.1 **oder** MPL-1.1 | Dynamisch gelinkt; im Release-Build werden `libtag`/`libtag_c` **unverändert** ins App-Bundle kopiert (Contents/Frameworks). Quellcode: taglib.org bzw. Homebrew-Formel `taglib`. |
| [MediaInfo](https://mediaarea.net/MediaInfo) | BSD-2-Clause | Nicht gebündelt — wird als externes Programm aufgerufen, falls installiert. |
| [ExifTool](https://exiftool.org) | Perl Artistic License | Nicht gebündelt — wird als externes Programm aufgerufen, falls installiert. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | Statisch im CLI-Tool `tagx`. |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT | Statisch in Core/CLI/App; ZIP-Container-Zugriff für EPUB. |
| [Calibre](https://calibre-ebook.com) `ebook-meta` | GPL-3.0 | Nicht gebündelt — wird als externes Programm aufgerufen, falls installiert (mobi/azw3/fb2). |
| [Sparkle](https://sparkle-project.org) | MIT (Teile BSD-ähnlich, siehe Projekt-LICENSE) | `Sparkle.framework` wird unverändert ins App-Bundle kopiert (Contents/Frameworks); liefert die Auto-Updates. |

Das App-Icon wurde mit MiniMax `image-01` generiert; die Nutzungsrechte an
generierten Inhalten liegen laut MiniMax Platform ToS beim Ersteller.
