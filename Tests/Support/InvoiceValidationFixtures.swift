import Foundation

public enum InvoiceValidationFixtures {
    public static let guideline = "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"
    public static let ubl = """
    <?xml version="1.0" encoding="UTF-8"?>
    <invoice:Invoice xmlns:invoice="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
      xmlns:b="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <b:CustomizationID>\(guideline)</b:CustomizationID>
      <b:ID><![CDATA[ABC]]></b:ID>
    </invoice:Invoice>
    """

    /// Selbst erzeugter PDF-Container; keine Rechnung oder Fremd-PDF im Repo.
    /// XML bleibt binär, damit auch UTF-16-Anhänge unverändert prüfbar sind.
    public static func pdf(attachments: [(name: String, xml: Data)], declaredName: String? = nil) -> Data {
        let fileIDs = attachments.indices.map { 5 + $0 * 2 }
        let xmpID = 5 + attachments.count * 2
        let names = zip(attachments, fileIDs).map { "(\($0.0.name)) \($0.1) 0 R" }.joined(separator: " ")
        let af = fileIDs.map { "\($0) 0 R" }.joined(separator: " ")
        let metadata = declaredName == nil ? "" : " /Metadata \(xmpID) 0 R"
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [\(names)] >> >> /AF [\(af)]\(metadata) >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>".utf8),
            Data("<< /Length 0 >>\nstream\n\nendstream".utf8),
        ]
        for (index, attachment) in attachments.enumerated() {
            let streamID = fileIDs[index] + 1
            objects.append(Data("<< /Type /Filespec /F (\(attachment.name)) /AFRelationship /Data /EF << /F \(streamID) 0 R >> >>".utf8))
            objects.append(Data("<< /Type /EmbeddedFile /Length \(attachment.xml.count) >>\nstream\n".utf8)
                + attachment.xml + Data("\nendstream".utf8))
        }
        if let declaredName {
            let xmp = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
              fx:DocumentFileName="\(declaredName)" fx:DocumentType="INVOICE" fx:ConformanceLevel="EN 16931"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8)
            objects.append(Data("<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>\nstream\n".utf8)
                + xmp + Data("\nendstream".utf8))
        }
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf += Data("\(index + 1) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        let xref = pdf.count
        pdf += Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets { pdf += Data(String(format: "%010d 00000 n \n", offset).utf8) }
        pdf += Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return pdf
    }
}
