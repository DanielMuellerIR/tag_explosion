// Cover-Werkzeuge der CLI: `tagx cover info|convert|from-folder|to-folder`.
// Die klassischen Unterbefehle (export/set/remove) bleiben in Tagx.swift.
//
// Alle Befehle verstehen Audio-/Videodateien (TagLib) und E-Books mit Cover
// (EPUB nativ, mobi/azw3/fb2 über Calibre). „Das Cover" ist immer das erste
// eingebettete Bild; weitere Bilder (Booklet, Rückseite) bleiben unangetastet.
import ArgumentParser
import Foundation
import TagExplosionCore

/// Cover einer Datei lesen — Audio über TagLib, E-Books über EbookTool. Für
/// den Schreibweg braucht das E-Book zusätzlich seine Kernfelder, daher
/// liefert das Lesen alles, was `CoverTarget.write` später braucht.
enum CoverTarget {
    case audio(FileSnapshot<TagData>)
    case ebook(FileSnapshot<EbookContents>)

    static func read(_ url: URL) throws -> CoverTarget {
        if MediaFormats.kind(of: url) == .ebook {
            guard EbookTool.supportsCover(url: url) else {
                throw ValidationError("This format cannot carry a cover: \(url.lastPathComponent)")
            }
            return .ebook(try EbookTool.readSnapshot(url: url, includeCover: true))
        }
        return .audio(try FileSnapshot.capture(at: url) { try TagFile.read(at: url) })
    }

    /// Erstes eingebettetes Bild oder nil.
    var cover: Artwork? {
        switch self {
        case .audio(let snapshot): return snapshot.value.artworks.first
        case .ebook(let snapshot): return snapshot.value.cover
        }
    }

    /// Ersetzt das Cover (erstes Bild) und schreibt über den abgesicherten
    /// Weg: Stempelprüfung, Papierkorb-Sicherung, atomarer Austausch.
    func write(cover artwork: Artwork, to url: URL) throws {
        switch self {
        case .audio(let snapshot):
            var artworks = snapshot.value.artworks
            if artworks.isEmpty { artworks = [artwork] } else { artworks[0] = artwork }
            try snapshot.requireCurrent(at: url)
            try TrashBackup.shared.backUp(url)
            try TagFile.write(artworks: artworks, to: url, expecting: snapshot.stamp)
        case .ebook(let snapshot):
            try EbookTool.requireSupportedCover(artwork.data, for: url)
            try snapshot.requireCurrent(at: url)
            try TrashBackup.shared.backUp(url)
            try EbookTool.write(url: url, fields: snapshot.value.fields, original: snapshot.value.fields,
                                coverUpdate: .set(artwork.data), expecting: snapshot.stamp)
        }
    }
}

extension Cover {

    // MARK: - info

    struct CoverInfo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Analyze embedded cover art (size, format, color) and check it against player-friendly rules.")

        @Argument(help: "Media or e-book file(s)") var files: [String]
        @Flag(name: .long, help: "Output as JSON") var json = false
        @Flag(name: .long, help: "Exit with code 3 if any cover has an issue or a file has no cover")
        var strict = false

        /// JSON-Struktur: je Datei alle eingebetteten Bilder mit Analyse.
        struct Report: Codable {
            struct Entry: Codable {
                var index: Int
                var pictureType: String
                var analysis: CoverAnalysis
            }
            var file: String
            var artworks: [Entry]
        }

        func run() throws {
            var reports: [Report] = []
            for path in files {
                let url = try resolveFile(path)
                let artworks: [Artwork]
                if MediaFormats.kind(of: url) == .ebook {
                    artworks = try EbookTool.readCover(url: url).map { [$0] } ?? []
                } else {
                    artworks = try TagFile.read(at: url).artworks
                }
                reports.append(Report(file: url.path, artworks: artworks.enumerated().map { i, art in
                    .init(index: i + 1, pictureType: art.pictureType, analysis: CoverTools.analyze(art.data))
                }))
            }
            if json {
                try printJSON(reports)
            } else {
                for report in reports {
                    if reports.count > 1 { print("== \(report.file)") }
                    if report.artworks.isEmpty { print("(no cover)") }
                    for entry in report.artworks {
                        let type = entry.pictureType.isEmpty ? "?" : entry.pictureType
                        print("#\(entry.index) \(type) · \(entry.analysis.summary)")
                        for issue in entry.analysis.issues {
                            print("  ! \(issue.code.rawValue): \(issue.message)")
                        }
                    }
                }
            }
            let hasProblem = reports.contains {
                $0.artworks.isEmpty || $0.artworks.contains { !$0.analysis.issues.isEmpty }
            }
            if strict, hasProblem { throw ExitCode(3) }
        }
    }

    // MARK: - convert

    struct CoverConvert: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "convert",
            abstract: "Shrink, re-encode, or strip the embedded cover and write it back into the file.",
            discussion: """
                --max-size shrinks only covers whose longer edge exceeds the limit (aspect \
                ratio is kept). --jpeg/--png always re-encode, even if the cover already has \
                that format. --strip-metadata alone removes EXIF/XMP/text chunks losslessly. \
                Only the first embedded image (the cover) is changed.
                """)

        @Argument(help: "Media or e-book file(s)") var files: [String]
        @Option(name: .long, help: "Maximum edge length in pixels (e.g. 500, 1000, 1500)")
        var maxSize: Int?
        @Option(name: .long, help: "Re-encode as JPEG with this quality (0–1, default 0.85)")
        var jpeg: Double?
        @Flag(name: .long, help: "Re-encode as PNG") var png = false
        @Flag(name: .long, help: "Remove EXIF/XMP/IPTC metadata and text chunks") var stripMetadata = false
        @OptionGroup var safeMode: SafeModeOptions

        func validate() throws {
            if maxSize == nil, jpeg == nil, !png, !stripMetadata {
                throw ValidationError("Provide at least one of --max-size, --jpeg, --png, --strip-metadata.")
            }
            if jpeg != nil, png { throw ValidationError("--jpeg and --png exclude each other.") }
            if let maxSize, maxSize < 1 { throw ValidationError("--max-size must be a positive number of pixels.") }
            if let jpeg, !(0...1).contains(jpeg) { throw ValidationError("--jpeg quality must be between 0 and 1.") }
        }

        func run() throws {
            safeMode.apply()
            let conversion = CoverTools.Conversion(
                maxPixelSize: maxSize,
                format: png ? .png : (jpeg != nil ? .jpeg : nil),
                jpegQuality: jpeg ?? 0.85,
                stripMetadata: stripMetadata)
            for path in files {
                let url = try resolveFile(path)
                let target = try CoverTarget.read(url)
                guard let cover = target.cover else {
                    FileHandle.standardError.write(Data("Note: no cover in \(url.lastPathComponent)\n".utf8))
                    continue
                }
                let converted = try CoverTools.convert(cover, conversion)
                guard converted.data != cover.data else {
                    print("OK \(url.lastPathComponent): cover unchanged")
                    continue
                }
                try target.write(cover: converted, to: url)
                let after = CoverTools.analyze(converted.data)
                print("OK \(url.lastPathComponent): cover \(cover.data.count) → \(converted.data.count) bytes · \(after.summary)")
            }
        }
    }

    // MARK: - from-folder

    struct CoverFromFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "from-folder",
            abstract: "Embed the folder cover (folder/cover/front .jpg/.png next to each file) as the file's cover.")

        @Argument(help: "Media or e-book file(s)") var files: [String]
        @OptionGroup var safeMode: SafeModeOptions

        func run() throws {
            safeMode.apply()
            // Erst alle Ordner-Cover finden, dann schreiben: Ein fehlendes
            // Cover bei Datei 3 soll nicht Datei 1 und 2 schon geändert haben.
            var jobs: [(url: URL, artwork: Artwork)] = []
            for path in files {
                let url = try resolveFile(path)
                let directory = url.deletingLastPathComponent()
                guard let artwork = try FolderCover.load(in: directory) else {
                    throw CoverToolError.noFolderCover(directory: directory.path)
                }
                jobs.append((url, artwork))
            }
            for job in jobs {
                let target = try CoverTarget.read(job.url)
                if target.cover?.data == job.artwork.data {
                    print("OK \(job.url.lastPathComponent): cover unchanged")
                    continue
                }
                try target.write(cover: job.artwork, to: job.url)
                print("OK \(job.url.lastPathComponent): cover set from \(FolderCover.find(in: job.url.deletingLastPathComponent())?.lastPathComponent ?? "folder cover")")
            }
        }
    }

    // MARK: - to-folder

    struct CoverToFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "to-folder",
            abstract: "Write the embedded cover as folder.jpg (or folder.png …, by image type) next to the file.")

        @Argument(help: "Media or e-book file") var file: String
        @Flag(name: .long, help: "Replace an existing folder cover (safety copy goes to the trash)")
        var force = false
        @OptionGroup var safeMode: SafeModeOptions

        func run() throws {
            safeMode.apply()
            let url = try resolveFile(file)
            guard let cover = try CoverTarget.read(url).cover else {
                throw ValidationError("No embedded cover in \(url.lastPathComponent)")
            }
            let target = try FolderCover.export(cover, to: url.deletingLastPathComponent(), force: force)
            print(target.path)
        }
    }
}
