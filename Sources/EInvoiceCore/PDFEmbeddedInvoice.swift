// Eingebettete Dateien und die Factur-X-/ZUGFeRD-Deklaration aus einem PDF
// lesen. Läuft über CoreGraphics (CGPDFDocument), also nur auf
// Apple-Plattformen — der einzige nicht Linux-portable Teil von EInvoiceCore,
// deshalb komplett in dieser Datei gekapselt.
//
// PDF-Struktur: Katalog → Names → EmbeddedFiles ist ein Namensbaum (direkt
// mit "Names" oder verschachtelt über "Kids"); jeder Eintrag ist ein
// Filespec-Dictionary mit "EF" → Stream. ZUGFeRD/Factur-X verlangen die
// Rechnung zusätzlich als "AF"-Array (Associated Files) im Katalog — beide
// Wege werden gelesen, doppelte Namen nur einmal übernommen.
#if canImport(CoreGraphics)
import Foundation
import CoreGraphics

enum PDFEmbeddedInvoice {

    struct EmbeddedFile {
        var name: String
        var data: Data
    }

    struct Extraction {
        var files: [EmbeddedFile]
        var declaration: EInvoicePDFDeclaration?
    }

    /// Obergrenzen der Extraktion: Ein PDF mit vielen oder stark komprimierten
    /// großen Anhängen darf die App beim Öffnen weder blockieren noch wegen
    /// Speichermangels beenden. Eine echte Rechnungsdatei ist klein und liegt
    /// unter den ersten Anhängen — die Grenzen sind großzügig gewählt.
    static let maxEmbeddedFiles = 32
    /// Anzeigebudget der Extraktion in ENTPACKTEN Bytes: So viel darf die
    /// Summe der BEHALTENEN Anhänge zusammen groß werden.
    static let maxTotalBytes = 64 * 1024 * 1024
    /// Zweites, höheres Budget für die geleistete ENTPACKARBEIT — auch für
    /// Anhänge, die danach verworfen werden. Es bremst die Wiederholung
    /// derselben Dekompressionsbombe im Namensbaum, ohne die Suche nach der
    /// Rechnung abzubrechen.
    ///
    /// Getrennte Budgets, weil ein einziger Zähler beides nicht leisten kann:
    /// Zählte die Entpackarbeit gegen das Anzeigebudget, machte EIN übergroßer
    /// Anhang vor der Rechnung jeden weiteren Kandidaten unerreichbar, und die
    /// Datei galt als „keine E-Rechnung" (Review-Fund 2026-08-20).
    static let materializedBudgetFactor = 4
    /// Grenze für die KOMPRIMIERTE Stream-Größe (deklariertes /Length).
    /// CGPDFStreamCopyData dekomprimiert immer vollständig im Speicher; die
    /// einzige Vorab-Schranke gegen eine Dekompressionsbombe ist deshalb die
    /// physisch in der Datei liegende Byte-Menge.
    ///
    /// 256 KiB heißt: eine EINZELNE Entpackung belegt kurzzeitig höchstens
    /// 256 KiB × 1032 ≈ 258 MiB. Das liegt bewusst über dem Gesamtbudget von
    /// 64 MiB, und der frühere Kommentar, der genau 64 MiB als Spitzenlast
    /// zusagte, war deshalb falsch (Review-Fund 2026-08-18). Die strenge
    /// Ableitung 64 MiB / 1032 ≈ 64 KiB scheidet aus, weil sie echte Rechnungen
    /// unsichtbar machen würde: Eine Rechnung mit 5000 Positionen ist roh gut
    /// 5 MiB groß und komprimiert rund 100 KiB (gemessen mit deflate -9). Eine
    /// kurzzeitige Allokation von 258 MiB übersteht eine Mac-App dagegen; die
    /// alten 8 MiB liessen rund 8 GiB zu (Review-Fund 2026-08-17).
    ///
    /// Wiederholung begrenzt der Materialisierungs-Zähler unten: Er zählt ALLE
    /// entpackten ANHANGS-Bytes, auch die verworfenen — sonst könnte dieselbe
    /// Bombe im Namensbaum tausendfach auftauchen und die App minutenlang
    /// beschäftigen. Der XMP-Metadatenstrom läuft nicht über diesen Zähler; für
    /// ihn gelten `maxCompressedMetadataBytes` und `maxMetadataBytes`.
    static let maxCompressedBytes = 256 * 1024
    /// Obergrenze besuchter Namensbaum-Knoten. Die reine Tiefengrenze ließe
    /// einen sich selbst referenzierenden /Kids-Knoten exponentiell viele
    /// Besuche erzeugen (2 Verweise × 32 Ebenen = 2^32) — das Budget deckelt
    /// die Gesamtarbeit; echte Bäume mit wenigen Anhängen bleiben weit darunter.
    static let maxNameTreeNodes = 4096
    /// Gemeinsames Arbeitsbudget fuer JEDEN untersuchten Eintrag: Array-Posten
    /// im /AF, Name-Filespec-Paar einer /Names-Liste, Eintrag eines /Kids-Arrays
    /// und jedes aufgeloeste Filespec. Das Knotenbudget zaehlte nur rekursive
    /// Dictionaries — eine einzige, beliebig lange /Names- oder /Kids-Liste lief
    /// trotzdem vollstaendig durch (Review-Fund 2026-08-17).
    static let maxInspectedEntries = 8192
    /// Grenze fuer den KOMPRIMIERTEN XMP-Metadatenstrom. XMP ist ein kleines
    /// XML-Dokument; Rechnungs-PDFs liegen weit darunter. Vorher wurde dieser
    /// Strom voellig ungeprueft materialisiert und geparst — ein grosser oder
    /// stark komprimierter /Metadata-Strom konnte die App schon beim blossen
    /// Oeffnen eines PDFs beenden (Review-Fund 2026-08-17).
    static let maxCompressedMetadataBytes = 64 * 1024
    /// Grenze fuer das ENTPACKTE XMP. 64 KiB komprimiert koennen bis zu ~64 MiB
    /// werden; geparst wird davon nur, was hier hineinpasst.
    static let maxMetadataBytes = 4 * 1024 * 1024

    /// Gemeinsamer Zaehler fuer das Arbeitsbudget.
    ///
    /// Bewusst ein Referenztyp: Der Namensbaum-Durchlauf und der Closure, der
    /// die gefundenen Filespecs aufnimmt, greifen beide darauf zu. Als `inout`
    /// waere das eine Exklusivitaetsverletzung — Swift bricht dabei mit
    /// „Fatal access conflict" ab.
    private final class WorkBudget {
        private var remaining: Int
        init(_ remaining: Int) { self.remaining = remaining }
        var isExhausted: Bool { remaining <= 0 }
        /// Einen Punkt verbrauchen. `false` heisst: nichts mehr uebrig.
        func consume() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    /// `byteBudget`: Anzeigebudget in ENTPACKTEN Bytes — so groß darf die
    /// Summe der behaltenen Anhänge werden. Die Entpackarbeit darf das
    /// `materializedBudgetFactor`-Fache davon erreichen. Nur Tests setzen die
    /// Werte klein, um die Grenzen ohne 64-MiB-Fixture zu prüfen.
    static func extract(url: URL, byteBudget: Int = maxTotalBytes) throws -> Extraction {
        guard let document = CGPDFDocument(url as CFURL),
              let catalog = document.catalog else {
            throw EInvoiceError.pdfUnreadable(url.path)
        }

        // Die XMP-Deklaration zuerst: Sie benennt die maßgebliche
        // Rechnungsdatei, die unten unabhängig vom Dateibudget aufgenommen
        // werden darf — sonst könnten 32 fremde XML-Anhänge vor ihr das
        // Budget aufbrauchen und eine gültige Rechnung unsichtbar machen.
        let declaration = readDeclaration(catalog: catalog)
        let declaredName = declaration?.documentFileName?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var files: [EmbeddedFile] = []
        var seenNames = Set<String>()
        // Was tatsächlich in `files` liegt. Dieser Zähler bestimmt die Ausgabe.
        var retainedBytes = 0
        // Alle entpackten ANHANGS-Bytes, auch die verworfenen. Ein Anhang, der
        // das Anzeigebudget sprengt, wird nicht übernommen — materialisiert war
        // er trotzdem. Ohne diesen Zähler durfte dieselbe Dekompressionsbombe
        // beliebig oft im Namensbaum stehen (Review-Fund 2026-08-18).
        var materializedBytes = 0
        let workBudget = byteBudget.multipliedReportingOverflow(by: materializedBudgetFactor)
        let materializedBudget = workBudget.overflow ? Int.max : workBudget.partialValue
        // Ein Budget fuer die GESAMTE Untersuchung: jeder Array-Posten, jedes
        // Name-Filespec-Paar und jedes aufgeloeste Filespec kostet einen Punkt.
        // Das frueher allein zaehlende Knotenbudget deckte nur die Rekursion ab
        // (Review-Fund 2026-08-17).
        let entryBudget = WorkBudget(maxInspectedEntries)

        // Vorauswahl über den Filespec-Namen, BEVOR der Stream dekomprimiert
        // wird: Nur XML-Kandidaten (Endung .xml oder ohne Endung) kommen als
        // Rechnung infrage — andere Anhänge werden gar nicht erst entpackt.
        func add(_ filespec: CGPDFDictionaryRef, fallbackName: String?) {
            guard entryBudget.consume() else { return }
            let name = filespecName(filespec) ?? fallbackName ?? "eingebettete-datei"
            // Die deklarierte Datei bekommt einen reservierten Platz jenseits
            // des Dateibudgets (seenNames hält sie einmalig); die Byte-Budgets
            // gelten unverändert auch für sie.
            let isDeclared = declaredName.map { name.lowercased() == $0 } ?? false
            guard files.count < maxEmbeddedFiles || isDeclared,
                  retainedBytes < byteBudget,
                  materializedBytes < materializedBudget else { return }
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext.isEmpty || ext == "xml" else { return }
            guard !seenNames.contains(name) else { return }
            guard let stream = filespecStream(filespec),
                  let declaredLength = acceptableStreamLength(stream, byteBudget: byteBudget)
            else { return }
            // Der Name wird auch dann vermerkt, wenn der Anhang gleich wieder
            // verworfen wird: Sonst entpackte derselbe Stream unter demselben
            // Namen erneut.
            seenNames.insert(name)
            // Die Entpackarbeit wird VOR dem Kopieren belastet. Ein Stream,
            // dessen Dekomprimierung erst am Ende scheitert, kostete sonst gar
            // nichts und durfte beliebig oft wiederholt werden.
            materializedBytes += declaredLength
            var format = CGPDFDataFormat.raw
            guard let cfData = CGPDFStreamCopyData(stream, &format) else { return }
            let data = cfData as Data
            // Nachbelastung: Bei einem gefilterten Stream war die deklarierte
            // Länge die KOMPRIMIERTE Größe; entpackt wurde mehr.
            materializedBytes += max(0, data.count - declaredLength)
            // Zu groß heißt „diesen überspringen", nicht „Suche beenden" —
            // die Rechnung kann hinter dem Füllanhang liegen.
            guard retainedBytes + data.count <= byteBudget else { return }
            retainedBytes += data.count
            files.append(EmbeddedFile(name: name, data: data))
        }

        // Weg 1: AF-Array (Associated Files) im Katalog. Es kommt bewusst VOR
        // dem generischen Namensbaum: ZUGFeRD/Factur-X verlangen die Rechnung
        // genau hier, und nur so kann ein Namensbaum voller fremder
        // XML-Anhänge das Dateibudget nicht vor der Rechnung aufbrauchen.
        var af: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(catalog, "AF", &af), let af {
            for i in 0..<CGPDFArrayGetCount(af) {
                // Auch ein ungueltiger Posten kostet Budget: Ein breites
                // /AF-Array voller Fuellwerte lief sonst komplett durch.
                guard entryBudget.consume() else { break }
                var filespec: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(af, i, &filespec), let filespec {
                    add(filespec, fallbackName: nil)
                }
            }
        }

        // Weg 2: Namensbaum Names → EmbeddedFiles
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var embedded: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded {
                var nodeBudget = maxNameTreeNodes
                walkNameTree(embedded, depth: 0, budget: &nodeBudget,
                             entryBudget: entryBudget) { name, filespec in
                    add(filespec, fallbackName: name)
                }
            }
        }

        return Extraction(files: files, declaration: declaration)
    }

    // MARK: - Namensbaum

    /// Namensbaum rekursiv ablaufen. `depth` begrenzt die Rekursionstiefe,
    /// `budget` die Gesamtzahl besuchter Knoten — ein zyklischer oder sich
    /// verzweigend selbst referenzierender Baum in einer kaputten Datei darf
    /// die App weder aufhängen noch lange blockieren.
    private static func walkNameTree(_ node: CGPDFDictionaryRef, depth: Int,
                                     budget: inout Int,
                                     entryBudget: WorkBudget,
                                     visit: (String?, CGPDFDictionaryRef) -> Void) {
        guard depth < 32, budget > 0, !entryBudget.isExhausted else { return }
        budget -= 1

        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names {
            // Flaches Array: [Name1, Filespec1, Name2, Filespec2, …]
            // Jedes Paar kostet Budget — auch ein ungueltiges. Eine einzige
            // /Names-Liste mit Millionen Eintraegen lief sonst vollstaendig
            // durch, obwohl das Knotenbudget laengst gereicht haette
            // (Review-Fund 2026-08-17).
            let count = CGPDFArrayGetCount(names)
            var i = 0
            while i + 1 < count {
                guard entryBudget.consume() else { return }
                var nameRef: CGPDFStringRef?
                var filespec: CGPDFDictionaryRef?
                let name = CGPDFArrayGetString(names, i, &nameRef)
                    ? nameRef.flatMap(pdfString) : nil
                if CGPDFArrayGetDictionary(names, i + 1, &filespec), let filespec {
                    visit(name, filespec)
                }
                i += 2
            }
        }

        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for i in 0..<CGPDFArrayGetCount(kids) {
                guard budget > 0, entryBudget.consume() else { return }
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, i, &kid), let kid {
                    walkNameTree(kid, depth: depth + 1, budget: &budget,
                                 entryBudget: entryBudget, visit: visit)
                }
            }
        }
    }

    /// Name aus dem Filespec-Dictionary; "UF" (Unicode) hat Vorrang vor "F".
    private static func filespecName(_ filespec: CGPDFDictionaryRef) -> String? {
        var nameRef: CGPDFStringRef?
        if CGPDFDictionaryGetString(filespec, "UF", &nameRef), let nameRef,
           let s = pdfString(nameRef) {
            return s
        }
        if CGPDFDictionaryGetString(filespec, "F", &nameRef), let nameRef,
           let s = pdfString(nameRef) {
            return s
        }
        return nil
    }

    /// Der Datenstrom eines Filespecs; er liegt unter EF/UF bzw. EF/F.
    /// Getrennt vom Namen, damit die Vorauswahl über den Namen laufen kann,
    /// OHNE den Stream zu dekomprimieren.
    private static func filespecStream(_ filespec: CGPDFDictionaryRef) -> CGPDFStreamRef? {
        var ef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(filespec, "EF", &ef), let ef else { return nil }
        var stream: CGPDFStreamRef?
        if !CGPDFDictionaryGetStream(ef, "UF", &stream) {
            _ = CGPDFDictionaryGetStream(ef, "F", &stream)
        }
        return stream
    }

    /// Größen-Vorprüfung VOR CGPDFStreamCopyData: Der Aufruf materialisiert
    /// den vollständig dekomprimierten Anhang im Speicher, eine inkrementelle
    /// Dekomprimierung bietet CoreGraphics nicht. Deshalb wird vorher
    /// begrenzt, was physisch begrenzbar ist:
    /// - Ein GEFILTERTER Stream: /Length (die komprimierten Bytes, die
    ///   tatsächlich in der Datei liegen) ≤ `maxCompressed` — Flate entpackt
    ///   höchstens ~1:1032, das deckelt die Spitzenlast einer einzelnen
    ///   Entpackung.
    /// - Ein UNGEFILTERTER Stream: /Length ist bereits die entpackte Größe,
    ///   eine Bombe ist damit ausgeschlossen. Hier gilt deshalb `byteBudget`.
    ///   Die enge Schranke hätte sonst eine gültige, unkomprimiert eingebettete
    ///   Rechnung abgewiesen — Factur-X schreibt keine Kompression vor
    ///   (Review-Fund 2026-08-20).
    /// - Keine Filterketten (/Filter-Array > 1): kaskadiertes Flate würde die
    ///   Entpackungsrate potenzieren; echte Rechnungs-PDFs nutzen das nie.
    /// - Ein deklariertes /Params/Size über dem Budget ist ein ehrlich
    ///   angekündigter Überlauf und wird sofort abgelehnt.
    /// Restrisiko (bewusst): siehe knowledge/e-rechnung-anzeige.md.
    ///
    /// Rückgabe: die deklarierte `/Length`, wenn der Stream durchgelassen wird,
    /// sonst nil. Der Aufrufer belastet damit sein Arbeitsbudget, BEVOR er
    /// kopiert.
    private static func acceptableStreamLength(
        _ stream: CGPDFStreamRef,
        maxCompressed: Int = maxCompressedBytes,
        byteBudget: Int = maxTotalBytes
    ) -> Int? {
        guard let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        // Eine gueltige, positive /Length ist PFLICHT. Fehlte sie oder war sie
        // keine Ganzzahl, liess die Pruefung den Stream vorher einfach durch —
        // und genau ein solcher Stream umging jede Groessenschranke
        // (Review-Fund 2026-08-17). Ein Stream ohne ehrliche Laengenangabe ist
        // ohnehin nicht regelkonform.
        var length: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Length", &length), length > 0 else {
            return nil
        }
        var filterArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Filter", &filterArray), let filterArray,
           CGPDFArrayGetCount(filterArray) > 1 {
            return nil
        }
        // Ohne Filter ist /Length die entpackte Größe; die Bomben-Schranke
        // greift dann nicht, es gilt allein das Budget.
        let limit = hasFilter(dict) ? maxCompressed : byteBudget
        guard length <= CGPDFInteger(limit) else { return nil }
        var params: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "Params", &params), let params {
            var size: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(params, "Size", &size),
               size > CGPDFInteger(byteBudget) {
                return nil
            }
        }
        return Int(length)
    }

    /// Trägt der Stream überhaupt einen Filter? /Filter darf ein Name oder ein
    /// Array sein; fehlt er, liegen die Daten roh in der Datei.
    private static func hasFilter(_ dict: CGPDFDictionaryRef) -> Bool {
        var name: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(dict, "Filter", &name) { return true }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Filter", &array), let array {
            return CGPDFArrayGetCount(array) > 0
        }
        return false
    }

    private static func pdfString(_ ref: CGPDFStringRef) -> String? {
        CGPDFStringCopyTextString(ref) as String?
    }

    // MARK: - XMP-Deklaration

    /// Factur-X-/ZUGFeRD-Deklaration aus dem XMP-Metadatenstrom des Katalogs.
    /// Erkennung über den Namensraum (…pdfa:CrossIndustryDocument…), nicht
    /// über das Präfix — das darf ein Erzeuger frei wählen.
    private static func readDeclaration(catalog: CGPDFDictionaryRef) -> EInvoicePDFDeclaration? {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else {
            return nil
        }
        // Dieselbe Vorpruefung wie fuer Anhaenge, nur enger: XMP ist ein
        // kleines XML-Dokument. Ohne sie materialisierte schon das Oeffnen
        // eines PDFs einen beliebig grossen Strom und baute daraus einen
        // vollstaendigen XML-Baum (Review-Fund 2026-08-17).
        // Der XMP-Strom hat sein EIGENES Paar Grenzen und zählt bewusst nicht
        // gegen das Anhangs-Budget: Er wird genau einmal je PDF gelesen, eine
        // Wiederholung gibt es hier nicht (Review-Fund 2026-08-20).
        guard acceptableStreamLength(stream, maxCompressed: maxCompressedMetadataBytes,
                                     byteBudget: maxMetadataBytes) != nil else {
            return nil
        }
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cfData as Data
        // Auch entpackt gilt eine Grenze: 64 KiB Flate koennen sich vervielfachen.
        guard data.count <= maxMetadataBytes else { return nil }
        guard let xmp = try? XMLTree.parse(data) else { return nil }

        var declaration = EInvoicePDFDeclaration()
        collectDeclaration(node: xmp, into: &declaration)
        return declaration.isEmpty ? nil : declaration
    }

    private static func collectDeclaration(node: XMLTreeNode,
                                           inheritedNamespaces: [String: String] = [:],
                                           into declaration: inout EInvoicePDFDeclaration) {
        // Präfix→URI-Bindungen dieses Teilbaums: geerbte plus die am Element
        // selbst deklarierten (innere Deklarationen überschreiben äußere).
        var namespaces = inheritedNamespaces
        for (prefix, uri) in node.namespaceDeclarations { namespaces[prefix] = uri }

        let isInvoiceNamespace = isInvoiceDeclarationNamespace(node.namespaceURI)
        if isInvoiceNamespace {
            let local = node.name.components(separatedBy: ":").last ?? node.name
            apply(local: local, value: node.text, to: &declaration)
        }
        // Kurzform: Werte als Attribute an rdf:Description. Entscheidend ist
        // der aufgelöste Namensraum des Attributs, nicht sein Präfix — ein
        // Erzeuger darf das Präfix frei wählen, und umgekehrt darf ein
        // fremdes, zufällig "fx" genanntes Schema keine Deklaration vortäuschen.
        for attribute in node.attributes {
            guard let colon = attribute.name.firstIndex(of: ":") else { continue }
            let prefix = String(attribute.name[..<colon])
            guard let uri = namespaces[prefix],
                  isInvoiceDeclarationNamespace(uri) else { continue }
            let local = String(attribute.name[attribute.name.index(after: colon)...])
            apply(local: local, value: attribute.value, to: &declaration)
        }
        for child in node.children {
            collectDeclaration(node: child, inheritedNamespaces: namespaces,
                               into: &declaration)
        }
    }

    /// Nur die veröffentlichten Factur-X-/ZUGFeRD-Namensraumfamilien
    /// akzeptieren. Eine bloße Teilzeichenfolge würde fremde XMP-Schemata als
    /// Rechnungsdeklaration deuten und könnte sogar die Anhangsauswahl lenken.
    private static func isInvoiceDeclarationNamespace(_ uri: String) -> Bool {
        [
            "urn:factur-x:pdfa:CrossIndustryDocument:",
            "urn:zugferd:pdfa:CrossIndustryDocument:",
            "urn:ferd:pdfa:CrossIndustryDocument:",
        ].contains(where: uri.hasPrefix)
    }

    private static func apply(local: String, value: String,
                              to declaration: inout EInvoicePDFDeclaration) {
        guard !value.isEmpty else { return }
        switch local {
        case "DocumentType": declaration.documentType = declaration.documentType ?? value
        case "DocumentFileName": declaration.documentFileName = declaration.documentFileName ?? value
        case "Version": declaration.version = declaration.version ?? value
        case "ConformanceLevel": declaration.conformanceLevel = declaration.conformanceLevel ?? value
        default: break
        }
    }
}
#endif
