import Foundation

extension InvoiceValidationFixtures {
    /// Eigener leerer PDF-Träger mit vollständiger PDF/A-Identifikation und
    /// Factur-X-Erweiterung. Die Bild-/XML-Inhaltsgleichheit wird damit nicht getestet.
    public static func hybridPDF(xml: Data, profile: String = "EN 16931", variant: String = "valid") -> Data {
        let isFour = variant == "pdfa4f"
        let isAccessible = variant == "pdfa3a"
        let conformance = isFour ? "F" : isAccessible ? "A" : variant == "pdfa3u" ? "U" : "B"
        let name = variant == "wrong-name" ? "other.xml" : variant == "legacy" ? "zugferd-invoice.xml" : "factur-x.xml"
        let declaredProfile = variant == "wrong-profile" ? "MINIMUM" : profile
        let relationship = variant == "wrong-relation" ? "Unspecified" : ["MINIMUM", "BASIC WL"].contains(profile) ? "Data" : "Alternative"
        let mime = variant == "wrong-mime" ? "application#2Fxml" : "text#2Fxml"
        let definitions = ["DocumentType", "DocumentFileName", "Version", "ConformanceLevel"].map { key in
            "<rdf:li rdf:parseType=\"Resource\"><pdfaProperty:name>\(key)</pdfaProperty:name><pdfaProperty:valueType>Text</pdfaProperty:valueType><pdfaProperty:category>external</pdfaProperty:category><pdfaProperty:description>Invoice metadata \(key)</pdfaProperty:description></rdf:li>"
        }.joined()
        let extensionSchema = variant == "missing-schema" ? "" : """
        <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#"><pdfaExtension:schemas><rdf:Bag><rdf:li rdf:parseType="Resource"><pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema><pdfaSchema:namespaceURI>urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#</pdfaSchema:namespaceURI><pdfaSchema:prefix>fx</pdfaSchema:prefix><pdfaSchema:property><rdf:Seq>\(definitions)</rdf:Seq></pdfaSchema:property></rdf:li></rdf:Bag></pdfaExtension:schemas></rdf:Description>
        """
        let identification = variant == "missing-pdfa" ? "" : """
        <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" pdfaid:part="\(isFour ? "4" : "3")" pdfaid:conformance="\(conformance)"\(isFour ? " pdfaid:rev=\"2020\"" : "")/>
        """
        var xmp = Data("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\(identification)<rdf:Description rdf:about="" xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#" fx:DocumentType="INVOICE" fx:DocumentFileName="\(name)" fx:Version="1.0" fx:ConformanceLevel="\(declaredProfile)"/>\(extensionSchema)</rdf:RDF></x:xmpmeta><?xpacket end="w"?>
        """.utf8)
        if variant == "legacy" {
            let text = String(decoding: xmp, as: UTF8.self)
                .replacingOccurrences(of: "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#", with: "urn:zugferd:pdfa:CrossIndustryDocument:invoice:1p0#")
                .replacingOccurrences(of: "fx:Version=\"1.0\"", with: "fx:Version=\"2p0\"")
                .replacingOccurrences(of: "fx:", with: "zf:")
                .replacingOccurrences(of: "xmlns:fx=", with: "xmlns:zf=")
                .replacingOccurrences(of: ">fx</pdfaSchema:prefix>", with: ">zf</pdfaSchema:prefix>")
            xmp = Data(text.utf8)
        }
        let extra = ["duplicate-invoice", "wrong-attachment"].contains(variant)
        let metadataID = extra ? 9 : 7
        let extraName = variant == "duplicate-invoice" ? "second.xml" : "file.bin"
        let names = variant == "missing-names" ? "" : " /Names << /EmbeddedFiles << /Names [(\(name)) 5 0 R\(extra ? " (\(extraName)) 7 0 R" : "")] >> >>"
        let af = variant == "missing-af" ? "" : " /AF [5 0 R\(extra ? " 7 0 R" : "")]"
        let structure = isAccessible ? " /Lang (de-DE) /MarkInfo << /Marked true >> /StructTreeRoot << /Type /StructTreeRoot /K [] >>" : ""
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /Metadata \(metadataID) 0 R\(af)\(names)\(structure) >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>".utf8),
            Data("<< /Length 0 >>\nstream\n\nendstream".utf8),
            Data("<< /Type /Filespec /F (\(name)) /UF (\(name)) /Desc (Test invoice) /AFRelationship /\(relationship) /EF << /F 6 0 R /UF 6 0 R >> >>".utf8),
            Data("<< /Type /EmbeddedFile /Subtype /\(mime) /Params << /Size \(xml.count) /ModDate (D:20261016060000Z) >> /Length \(xml.count) >>\nstream\n".utf8) + xml + Data("\nendstream".utf8),
        ]
        if extra {
            let bytes = variant == "duplicate-invoice" ? xml : Data("test".utf8)
            objects += [Data("<< /Type /Filespec /F (\(extraName)) /UF (\(extraName)) /Desc (Extra test file) /AFRelationship /Supplement /EF << /F 8 0 R /UF 8 0 R >> >>".utf8),
                        Data("<< /Type /EmbeddedFile /Subtype /\(variant == "duplicate-invoice" ? "text#2Fxml" : "application#2Foctet-stream") /Params << /Size \(bytes.count) /ModDate (D:20261016060000Z) >> /Length \(bytes.count) >>\nstream\n".utf8) + bytes + Data("\nendstream".utf8)]
        }
        objects.append(Data("<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>\nstream\n".utf8) + xmp + Data("\nendstream".utf8))
        var pdf = Data("%PDF-\(isFour ? "2.0" : "1.7")\n%".utf8) + Data([0xe2, 0xe3, 0xcf, 0xd3, 0x0a])
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf += Data("\(index + 1) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        let xref = pdf.count
        pdf += Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets { pdf += Data(String(format: "%010d 00000 n \n", offset).utf8) }
        pdf += Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /ID [<00112233445566778899aabbccddeeff><00112233445566778899aabbccddeeff>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return pdf
    }
}
