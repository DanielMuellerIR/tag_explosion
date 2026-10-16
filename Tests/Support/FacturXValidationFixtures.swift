import Foundation

extension InvoiceValidationFixtures {
    public static let facturXProfiles: [(name: String, guideline: String)] = [
        ("MINIMUM", "urn:factur-x.eu:1p0:minimum"),
        ("BASICWL", "urn:factur-x.eu:1p0:basicwl"),
        ("BASIC", "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic"),
        ("EN16931", "urn:cen.eu:en16931:2017"),
        ("EXTENDED", "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended"),
    ]

    /// Ausschließlich selbst erzeugte, kleine Rechnungen für die Profilabnahme.
    public static func facturX(profile: String) -> String {
        let guideline = facturXProfiles.first { $0.name == profile }!.guideline
        let minimum = profile == "MINIMUM"
        let withLines = !["MINIMUM", "BASICWL"].contains(profile)
        let line = withLines ? """
          <ram:IncludedSupplyChainTradeLineItem>
            <ram:AssociatedDocumentLineDocument><ram:LineID>1</ram:LineID></ram:AssociatedDocumentLineDocument>
            <ram:SpecifiedTradeProduct><ram:Name>Test item</ram:Name></ram:SpecifiedTradeProduct>
            <ram:SpecifiedLineTradeAgreement><ram:NetPriceProductTradePrice><ram:ChargeAmount>100.00</ram:ChargeAmount></ram:NetPriceProductTradePrice></ram:SpecifiedLineTradeAgreement>
            <ram:SpecifiedLineTradeDelivery><ram:BilledQuantity unitCode="C62">1</ram:BilledQuantity></ram:SpecifiedLineTradeDelivery>
            <ram:SpecifiedLineTradeSettlement>
              <ram:ApplicableTradeTax><ram:TypeCode>VAT</ram:TypeCode><ram:CategoryCode>S</ram:CategoryCode><ram:RateApplicablePercent>19</ram:RateApplicablePercent></ram:ApplicableTradeTax>
              <ram:SpecifiedTradeSettlementLineMonetarySummation><ram:LineTotalAmount>100.00</ram:LineTotalAmount></ram:SpecifiedTradeSettlementLineMonetarySummation>
            </ram:SpecifiedLineTradeSettlement>
          </ram:IncludedSupplyChainTradeLineItem>
        """ : ""
        let buyerAddress = minimum ? "" : """
          <ram:PostalTradeAddress><ram:PostcodeCode>12345</ram:PostcodeCode><ram:LineOne>Test street 2</ram:LineOne><ram:CityName>Test city</ram:CityName><ram:CountryID>DE</ram:CountryID></ram:PostalTradeAddress>
        """
        let settlement = minimum ? "" : """
          <ram:ApplicableTradeTax><ram:CalculatedAmount>19.00</ram:CalculatedAmount><ram:TypeCode>VAT</ram:TypeCode><ram:BasisAmount>100.00</ram:BasisAmount><ram:CategoryCode>S</ram:CategoryCode><ram:RateApplicablePercent>19</ram:RateApplicablePercent></ram:ApplicableTradeTax>
          <ram:SpecifiedTradePaymentTerms><ram:Description>Payment due immediately.</ram:Description></ram:SpecifiedTradePaymentTerms>
        """
        let delivery = withLines ? "<ram:ActualDeliverySupplyChainEvent><ram:OccurrenceDateTime><udt:DateTimeString format=\"102\">20261016</udt:DateTimeString></ram:OccurrenceDateTime></ram:ActualDeliverySupplyChainEvent>" : ""
        let sellerAddress = minimum ? "<ram:CountryID>DE</ram:CountryID>" : "<ram:PostcodeCode>12345</ram:PostcodeCode><ram:LineOne>Test street 1</ram:LineOne><ram:CityName>Test city</ram:CityName><ram:CountryID>DE</ram:CountryID>"
        let lineTotal = minimum ? "" : "<ram:LineTotalAmount>100.00</ram:LineTotalAmount>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100" xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
          <rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter><ram:ID>\(guideline)</ram:ID></ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>
          <rsm:ExchangedDocument><ram:ID>TEST-1</ram:ID><ram:TypeCode>380</ram:TypeCode><ram:IssueDateTime><udt:DateTimeString format="102">20261016</udt:DateTimeString></ram:IssueDateTime></rsm:ExchangedDocument>
          <rsm:SupplyChainTradeTransaction>
            \(line)
            <ram:ApplicableHeaderTradeAgreement>
              <ram:SellerTradeParty><ram:Name>Test Seller</ram:Name><ram:SpecifiedLegalOrganization><ram:ID>TEST-SELLER</ram:ID></ram:SpecifiedLegalOrganization><ram:PostalTradeAddress>\(sellerAddress)</ram:PostalTradeAddress><ram:SpecifiedTaxRegistration><ram:ID schemeID="VA">DE123456789</ram:ID></ram:SpecifiedTaxRegistration></ram:SellerTradeParty>
              <ram:BuyerTradeParty><ram:Name>Test Buyer</ram:Name>\(buyerAddress)</ram:BuyerTradeParty>
            </ram:ApplicableHeaderTradeAgreement>
            <ram:ApplicableHeaderTradeDelivery>\(delivery)</ram:ApplicableHeaderTradeDelivery>
            <ram:ApplicableHeaderTradeSettlement>
              <ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>
              \(settlement)
              <ram:SpecifiedTradeSettlementHeaderMonetarySummation>\(lineTotal)<ram:TaxBasisTotalAmount>100.00</ram:TaxBasisTotalAmount><ram:TaxTotalAmount currencyID="EUR">19.00</ram:TaxTotalAmount><ram:GrandTotalAmount>119.00</ram:GrandTotalAmount><ram:DuePayableAmount>119.00</ram:DuePayableAmount></ram:SpecifiedTradeSettlementHeaderMonetarySummation>
            </ram:ApplicableHeaderTradeSettlement>
          </rsm:SupplyChainTradeTransaction>
        </rsm:CrossIndustryInvoice>
        """
    }
}
