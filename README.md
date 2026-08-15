<p align="center">
  <img src="docs/app-icon.png" width="128" alt="Tag Explosion icon">
</p>

<h1 align="center">Tag Explosion</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Native macOS app for viewing and editing media metadata — audio tags,
  image metadata (EXIF/IPTC/XMP), video tags, and e-book metadata in one fast,
  Apple-style editor, with a scriptable CLI companion. Also inspects
  e-invoices (ZUGFeRD/Factur-X, XRechnung, Peppol), read-only.</strong>
</p>

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg">
  <img alt="Platform: macOS 14+" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange.svg">
</p>

![Editing an audiobook: cover art, tags, and per-field copy menus](docs/screenshots/en/audio.png)
*The audio editor: cover art, all tag fields, and a copy menu on every field.*

## Features

- **Audio** — every tag field including custom keys, cover art, and batch
  editing: shared fields, track numbering, titles from file names, one cover
  for all files.
- **Images** — EXIF/IPTC/XMP harmonized the MWG way (title, description,
  keywords, creator, copyright, date, rating, GPS), plus a complete read-only
  view of all raw metadata groups.
- **Video** — MP4 and Matroska tags editable; other containers shown
  read-only.
- **E-books/documents** — the Calibre-style metadata set (title, authors,
  series, description, cover, ISBN, publisher, language, date, tags). EPUB is
  handled natively, PDF via exiftool; with Calibre installed, mobi/azw3/fb2
  are edited through its `ebook-meta` CLI.
- **E-invoices (read-only)** — detects the standard and profile from the
  specification identifier (BT-24): ZUGFeRD 2.x/Factur-X (MINIMUM through
  EXTENDED), XRechnung, Peppol BIS and plain EN 16931, in both syntaxes
  (UN/CEFACT CII and OASIS UBL, invoices and credit notes). Every populated
  field is shown with its EN 16931 business term (BT/BG number and label);
  unmapped fields stay visible with their raw path, and common codes are
  decoded (document type, VAT category, payment means, units). Works on
  standalone XML files and on PDFs with an embedded invoice, which get an
  extra "E-Invoice" tab.
- **Copy values between tags** — every text field (single-file and batch) can
  take its value from another tag, per file. Works across tag formats (for
  example EXIF → IPTC/XMP), restricted to type-compatible text fields.
- **Safe mode** — before every change, an untouched copy of the file goes to
  the trash, and every write goes through a checked copy of the file. See
  [Keeping your files safe](#keeping-your-files-safe).
- **Tag export/import with auto-backup** — the batch editors export all tags
  of a selection (covers embedded) into one self-contained JSON file and
  restore from it; before batch saves the app automatically writes a
  `tags-backup-<timestamp>.json` next to the files (setting, on by default).
- **Tech panel** — the full `mediainfo` report for any file, filterable and
  copyable.
- **Auto-updates** — via [Sparkle](https://sparkle-project.org); the app only
  installs updates after you confirm.
- **CLI `tagx`** — everything scriptable with JSON output and exit codes:
  `tagx show --json`, `tagx set`, `tagx cover`, `tagx info`, `tagx exif`,
  `tagx ebook`, `tagx invoice`.

The app's user interface is available in English and German (it follows the
system language); the CLI speaks English. One exception: the e-invoice view
labels fields with the official German EN 16931 business-term names (as used
by the German XRechnung specification) in both app and CLI — the BT/BG
numbers next to them are language-independent.

![Batch editing an album](docs/screenshots/en/batch.png)
*Batch editing: one change applies to all selected files; the copy menus fill
each file from one of its own tags.*

![Image metadata editor](docs/screenshots/en/image.png)
*The image editor with MWG-harmonized EXIF/IPTC/XMP fields.*

![E-book metadata editor](docs/screenshots/en/ebook.png)
*The e-book editor: Calibre-style metadata plus cover for EPUB, PDF, and
Calibre formats.*

## Keeping your files safe

Tag Explosion edits files you cannot easily recreate. Losing an audiobook or a
scanned photo to a botched write would be a poor trade for a corrected artist
name, so the app is built to make that outcome unlikely — and recoverable when
it happens anyway.

**Every change is written to a copy first.** The new version is created next to
the original, then checked (does the file still open, are channels, sample rate
and duration unchanged, is the cover count right), and only then does it replace
the original in a single atomic step. A crash, a format error or a full disk
cannot leave a half-written file behind: either the change is complete, or the
original is untouched. On APFS the copy is a clone, so this costs neither
noticeable time nor disk space.

**Safe mode puts the previous version in the trash.** Before each change, an
untouched copy of the file goes to the trash — collected in one folder per
session and per volume, named `Tag Explosion Backup <timestamp>`. If a change
turns out to be wrong, drag the copy back. To clean up, empty the trash; nothing
piles up in a hidden folder you never look at. On APFS the copy is a clone
again, so it only takes up the space that actually changes. Safe mode is on by
default while the app is young; turn it off under ⌘, or with `--no-backup` /
`TAGX_NO_BACKUP=1` in the CLI.

**Changes made by other programs are not overwritten silently.** If a file
changed on disk after you opened it, saving stops and asks. Choosing "Save
anyway" is safe as well: the state currently on disk is what safe mode copies to
the trash. Metadata reads are checked before and after as one snapshot — e-book
fields and cover together — and checked again before a no-op result or the
atomic replacement. Replacing a file at the same path is detected by its changed
file identity, not mistaken for the file that was read.

**Before writing, the app checks that there is room.** A batch that would run
out of disk space is refused instead of started.

**Batch saves also write a tag backup.** Before saving more than one file, a
`tags-backup-<timestamp>.json` with the previous state (covers included) is
written next to the files, restorable through the same import path or
`tagx import`.

**Formats the app cannot write safely stay read-only.** Containers that TagLib
cannot write, PDFs without cover support, and e-book formats that need Calibre
but do not have it are shown, not edited. A field that a format cannot store is
rejected before anything is written, not silently dropped.

**Verified by tests, not by hope.** The test suite checks that the audio stream
is bit-identical before and after a tag write, that a failed write leaves the
original byte-for-byte intact, that a read-only file, a read-only folder and a
genuinely full disk are refused, that broken and hostile input (empty,
truncated, random bytes, a leading dash in the file name) cannot damage
anything, and that the trash copy really holds the state from before the change.
These run on every push (see `.github/workflows/tests.yml`).

## Supported formats

| Media | File formats | Tag formats |
|-------|--------------|-------------|
| Audio | mp3, m4a, m4b, m4r, mp4, aac, flac, ogg, oga, opus, spx, wav, aiff, aif, wv, ape, mpc, tta, dsf, dff, wma, asf | ID3v1/v2, MP4 atoms, Vorbis Comments, APEv2, ASF, RIFF INFO |
| Images | jpg, jpeg, png, heic, heif, tif, tiff, webp, dng, gif | EXIF, IPTC, XMP (MWG-harmonized) |
| Video | mp4, m4v, mkv, webm (editable) · mov, avi (view only) | MP4 atoms, Matroska tags |
| E-books | epub, pdf · mobi, azw3, fb2 (with Calibre) | EPUB OPF, PDF Info/XMP (PDF: no series/cover) |
| E-invoices (view only) | xml · pdf (embedded invoice) | ZUGFeRD/Factur-X, XRechnung, Peppol BIS, EN 16931 — CII and UBL, fields labeled with BT/BG terms |

![Start screen with the format overview](docs/screenshots/en/empty.png)
*The start screen lists every supported file and tag format.*

## Installation

Download the notarized DMG from the
[Releases](../../releases) page, open it, and drag `TagExplosion.app` onto the
`Applications` folder. `TagExplosion.app` is Apple-Silicon-only (`arm64`) and
requires macOS 14 or later. There is no Intel/x86_64 or universal build.

TagLib ships inside the app bundle. For the full feature set install the two
external tools the app calls:

```sh
brew install mediainfo exiftool   # tech panel, image and PDF metadata
```

If the tools are missing, the app offers this itself at every launch: with
Homebrew present it installs the missing formulae on click, without Homebrew
it points to [brew.sh](https://brew.sh). The offer stops once nothing is
missing or "Don't Ask Again" is chosen.

Optional: with [Calibre](https://calibre-ebook.com) installed the app also
edits mobi/azw3/fb2 through its `ebook-meta` command line tool.

Later updates arrive through the built-in updater
(**Tag Explosion → Check for Updates …**). It fetches the update feed from
GitHub Pages; the app sends no other data.

## CLI

```sh
tagx show --json song.mp3                      # all tags as JSON
tagx set song.mp3 -t ARTIST="Miles Davis"      # set fields
tagx set song.mp3 -c ALBUMARTIST=ARTIST        # copy one tag into another
tagx cover set song.mp3 cover.jpg              # embed cover art
tagx exif set photo.jpg --copy description=IFD0:ImageDescription
tagx ebook set book.epub --series "Foundation" --series-index 2
tagx export Album/ -o tags.json                # back up all tags (covers embedded)
tagx import --dry-run tags.json                # preview a restore
tagx info video.mkv                            # full mediainfo report
tagx invoice invoice.pdf                       # e-invoice profile + all fields (BT terms)
tagx set song.mp3 -t ARTIST="X" --no-backup    # skip the safety copy in the trash
```

Imports only target files inside the JSON file's directory by default. An
archive that intentionally references external files requires the explicit
`--allow-external-targets` flag; `tagx` prints the complete resolved target
list before applying it. Ratings accept only integers from 0 through 5; only
an explicitly empty `--rating` value deletes the field.

## Building from source

Requirements: Xcode toolchain, Homebrew with `taglib`; `mediainfo` at
runtime, optional `exiftool` and `ffmpeg` for the tests.

```sh
./build.sh          # builds tagx and TagExplosion.app in the project folder
swift test          # tests generate their own fixtures
swift test --package-path App   # app tests (headless, no window)
```

With an Apple Developer ID in the keychain there are two more scripts. Both ask
once for the local notarytool keychain profile and remember its name for this
clone only:

```sh
./install.sh        # notarized build, installed to /Applications
./release.sh        # notarized DMG with background image, ready to publish
```

`install.sh` copies to `/Applications` only after stapler, Gatekeeper and the
signature confirm the bundle really is notarized; `./install.sh --no-notarize`
builds a quick test bundle that stays in the project folder. If the installed
bundle fails its final checks, an existing installation is restored; a rejected
first installation is removed again.

The core library and CLI are kept free of AppKit/SwiftUI so they stay portable
to Linux. See [docs/PLAN.md](docs/PLAN.md) for architecture and milestones and
[docs/sparkle-release.md](docs/sparkle-release.md) for the release process.

## License

MIT (see [LICENSE](LICENSE)), © 2026 Daniel Müller.

TagLib (LGPL-2.1-or-later or MPL-1.1) is linked dynamically and shipped
inside the app bundle, so it stays replaceable. The library code itself is
untouched; bundling only rewrites the install names to point at the bundle's
framework folder and re-signs the files. Sparkle (MIT),
ZIPFoundation (MIT), and swift-argument-parser (Apache-2.0) are linked as
well. mediainfo (BSD-2), exiftool (Artistic/GPL), and Calibre's `ebook-meta`
(GPL) are neither bundled nor linked — they are only invoked as external
programs. The e-invoice field labels follow the semantic model of EN 16931
and the UNTDID/UN/ECE code lists; no text from the standard documents is
reproduced, the short labels are written in the project's own wording. Full
licence texts and the reasoning:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

The demo files and cover art in the screenshots are entirely generated for
this documentation — the titles, authors, and artists do not exist.
