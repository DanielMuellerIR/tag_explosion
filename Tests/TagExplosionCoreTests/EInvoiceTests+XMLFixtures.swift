// Synthetische Rechnungs- und Bestelldaten für XML-Leser und PDF-Einbettung.
import Foundation

extension EInvoiceTests {
    /// Minimale CII-Rechnung (EN-16931-Profil) mit den Sonderfällen, die die
    /// dynamische Zuordnung abdecken muss: Steuernummer UND USt-IdNr. beim
    /// Verkäufer, Nachlass + Zuschlag auf Dokumentenebene, Steuersumme in
    /// Fremdwährung. Absichtlich mit ungewöhnlichen Namensraum-Präfixen —
    /// die Zuordnung darf nur über die Namensraum-URIs laufen.
    static let ciiXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <a:CrossIndustryInvoice
      xmlns:a="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      xmlns:b="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
      xmlns:c="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
      <a:ExchangedDocumentContext>
        <b:GuidelineSpecifiedDocumentContextParameter>
          <b:ID>urn:cen.eu:en16931:2017</b:ID>
        </b:GuidelineSpecifiedDocumentContextParameter>
      </a:ExchangedDocumentContext>
      <a:ExchangedDocument>
        <b:ID>R-1</b:ID>
        <b:TypeCode>380</b:TypeCode>
        <b:IssueDateTime><c:DateTimeString format="102">20260814</c:DateTimeString></b:IssueDateTime>
      </a:ExchangedDocument>
      <a:SupplyChainTradeTransaction>
        <b:IncludedSupplyChainTradeLineItem>
          <b:AssociatedDocumentLineDocument><b:LineID>1</b:LineID></b:AssociatedDocumentLineDocument>
          <b:SpecifiedTradeProduct><b:Name>Testartikel</b:Name></b:SpecifiedTradeProduct>
          <b:SpecifiedLineTradeAgreement>
            <b:NetPriceProductTradePrice>
              <b:ChargeAmount>49.50</b:ChargeAmount>
              <b:BasisQuantity unitCode="HUR">1</b:BasisQuantity>
            </b:NetPriceProductTradePrice>
          </b:SpecifiedLineTradeAgreement>
          <b:SpecifiedLineTradeDelivery>
            <b:BilledQuantity unitCode="HUR">2</b:BilledQuantity>
          </b:SpecifiedLineTradeDelivery>
          <b:SpecifiedLineTradeSettlement>
            <b:SpecifiedTradeAllowanceCharge>
              <b:ChargeIndicator><c:Indicator>false</c:Indicator></b:ChargeIndicator>
              <b:ActualAmount>1.00</b:ActualAmount>
            </b:SpecifiedTradeAllowanceCharge>
            <b:SpecifiedTradeSettlementLineMonetarySummation>
              <b:LineTotalAmount>99.00</b:LineTotalAmount>
            </b:SpecifiedTradeSettlementLineMonetarySummation>
          </b:SpecifiedLineTradeSettlement>
        </b:IncludedSupplyChainTradeLineItem>
        <b:ApplicableHeaderTradeAgreement>
          <b:SellerTradeParty>
            <b:Name>Verkäufer GmbH</b:Name>
            <b:SpecifiedTaxRegistration><b:ID schemeID="FC">1/23/456</b:ID></b:SpecifiedTaxRegistration>
            <b:SpecifiedTaxRegistration><b:ID schemeID="VA">DE999999999</b:ID></b:SpecifiedTaxRegistration>
          </b:SellerTradeParty>
          <b:BuyerTradeParty>
            <b:Name>Käufer AG</b:Name>
          </b:BuyerTradeParty>
        </b:ApplicableHeaderTradeAgreement>
        <b:ApplicableHeaderTradeDelivery/>
        <b:ApplicableHeaderTradeSettlement>
          <b:InvoiceCurrencyCode>EUR</b:InvoiceCurrencyCode>
          <b:SpecifiedTradeAllowanceCharge>
            <b:ChargeIndicator><c:Indicator>0</c:Indicator></b:ChargeIndicator>
            <b:ActualAmount>5.00</b:ActualAmount>
            <b:Reason>Treuerabatt</b:Reason>
          </b:SpecifiedTradeAllowanceCharge>
          <b:SpecifiedTradeAllowanceCharge>
            <b:ChargeIndicator><c:Indicator>1</c:Indicator></b:ChargeIndicator>
            <b:ActualAmount>3.00</b:ActualAmount>
            <b:Reason>Versand</b:Reason>
          </b:SpecifiedTradeAllowanceCharge>
          <b:SpecifiedTradeAllowanceCharge>
            <b:ChargeIndicator><c:Indicator>vielleicht</c:Indicator></b:ChargeIndicator>
            <b:ActualAmount>7.00</b:ActualAmount>
          </b:SpecifiedTradeAllowanceCharge>
          <b:SpecifiedTradeSettlementHeaderMonetarySummation>
            <b:TaxTotalAmount currencyID="EUR">18.62</b:TaxTotalAmount>
            <b:TaxTotalAmount currencyID="CHF">17.90</b:TaxTotalAmount>
            <b:GrandTotalAmount>115.62</b:GrandTotalAmount>
            <b:DuePayableAmount>115.62</b:DuePayableAmount>
          </b:SpecifiedTradeSettlementHeaderMonetarySummation>
        </b:ApplicableHeaderTradeSettlement>
      </a:SupplyChainTradeTransaction>
    </a:CrossIndustryInvoice>
    """

    /// Minimale UBL-Rechnung im XRechnung-3.0-Profil.
    static let ublXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</cbc:CustomizationID>
      <cbc:ProfileID>urn:fdc:peppol.eu:2017:poacc:billing:01:1.0</cbc:ProfileID>
      <cbc:ID>UBL-7</cbc:ID>
      <cbc:IssueDate>2026-08-14</cbc:IssueDate>
      <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
      <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
      <cbc:BuyerReference>04011000-1234-56</cbc:BuyerReference>
      <cac:AccountingSupplierParty>
        <cac:Party>
          <cac:PartyTaxScheme>
            <cbc:CompanyID>DE111111111</cbc:CompanyID>
            <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
          </cac:PartyTaxScheme>
          <cac:PartyLegalEntity>
            <cbc:RegistrationName>Anbieterin e.K.</cbc:RegistrationName>
          </cac:PartyLegalEntity>
        </cac:Party>
      </cac:AccountingSupplierParty>
      <cac:AccountingCustomerParty>
        <cac:Party>
          <cac:PartyLegalEntity>
            <cbc:RegistrationName>Kundin GmbH</cbc:RegistrationName>
          </cac:PartyLegalEntity>
        </cac:Party>
      </cac:AccountingCustomerParty>
      <cac:AdditionalDocumentReference>
        <cbc:ID>OBJ-1</cbc:ID>
        <cbc:DocumentTypeCode>130</cbc:DocumentTypeCode>
      </cac:AdditionalDocumentReference>
      <cac:AdditionalDocumentReference>
        <cbc:ID>BELEG-1</cbc:ID>
        <cbc:DocumentDescription>Stundenzettel</cbc:DocumentDescription>
      </cac:AdditionalDocumentReference>
      <cac:PaymentMeans>
        <cbc:PaymentMeansCode name="Überweisung">30</cbc:PaymentMeansCode>
      </cac:PaymentMeans>
      <cac:AllowanceCharge>
        <cbc:ChargeIndicator>1</cbc:ChargeIndicator>
        <cbc:AllowanceChargeReason>Versand</cbc:AllowanceChargeReason>
        <cbc:Amount currencyID="EUR">3.00</cbc:Amount>
      </cac:AllowanceCharge>
      <cac:AllowanceCharge>
        <cbc:ChargeIndicator>0</cbc:ChargeIndicator>
        <cbc:AllowanceChargeReason>Treuerabatt</cbc:AllowanceChargeReason>
        <cbc:Amount currencyID="EUR">5.00</cbc:Amount>
      </cac:AllowanceCharge>
      <cac:TaxTotal>
        <cbc:TaxAmount currencyID="EUR">19.00</cbc:TaxAmount>
      </cac:TaxTotal>
      <cac:LegalMonetaryTotal>
        <cbc:PayableAmount currencyID="EUR">119.00</cbc:PayableAmount>
      </cac:LegalMonetaryTotal>
      <cac:InvoiceLine>
        <cbc:ID>1</cbc:ID>
        <cbc:InvoicedQuantity unitCode="C62">1</cbc:InvoicedQuantity>
        <cbc:LineExtensionAmount currencyID="EUR">100.00</cbc:LineExtensionAmount>
        <cac:Item><cbc:Name>Dienstleistung</cbc:Name></cac:Item>
        <cac:Price>
          <cbc:PriceAmount currencyID="EUR">100.00</cbc:PriceAmount>
          <cbc:BaseQuantity unitCode="C62">1</cbc:BaseQuantity>
        </cac:Price>
      </cac:InvoiceLine>
    </Invoice>
    """

    /// UBL-Gutschrift: prüft die Pfad-Normalisierung (CreditNote → Invoice).
    static let ublCreditNoteXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CreditNote xmlns="urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0</cbc:CustomizationID>
      <cbc:ID>G-9</cbc:ID>
      <cbc:IssueDate>2026-08-01</cbc:IssueDate>
      <cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>
      <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
      <cac:CreditNoteLine>
        <cbc:ID>1</cbc:ID>
        <cbc:CreditedQuantity unitCode="C62">1</cbc:CreditedQuantity>
        <cac:Item><cbc:Name>Rückvergütung</cbc:Name></cac:Item>
      </cac:CreditNoteLine>
    </CreditNote>
    """


    /// Order-X-Bestellung (COMFORT) in CIO-Syntax — mit ungewöhnlichen
    /// Präfixen, Zuschlag auf Kopfebene und einem Beteiligten mit Anschrift.
    static let orderXXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <o:SCRDMCCBDACIOMessageStructure
      xmlns:o="urn:un:unece:uncefact:data:SCRDMCCBDACIOMessageStructure:100"
      xmlns:r="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:128"
      xmlns:u="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:128">
      <o:ExchangedDocumentContext>
        <r:GuidelineSpecifiedDocumentContextParameter>
          <r:ID>urn:order-x.eu:1p0:comfort</r:ID>
        </r:GuidelineSpecifiedDocumentContextParameter>
      </o:ExchangedDocumentContext>
      <o:ExchangedDocument>
        <r:ID>B-2026-7</r:ID>
        <r:TypeCode>220</r:TypeCode>
        <r:IssueDateTime><u:DateTimeString format="102">20260901</u:DateTimeString></r:IssueDateTime>
      </o:ExchangedDocument>
      <o:SupplyChainTradeTransaction>
        <r:IncludedSupplyChainTradeLineItem>
          <r:AssociatedDocumentLineDocument><r:LineID>1</r:LineID></r:AssociatedDocumentLineDocument>
          <r:SpecifiedTradeProduct><r:Name>Schrauben M4</r:Name></r:SpecifiedTradeProduct>
          <r:SpecifiedLineTradeAgreement>
            <r:NetPriceProductTradePrice><r:ChargeAmount>0.10</r:ChargeAmount></r:NetPriceProductTradePrice>
          </r:SpecifiedLineTradeAgreement>
          <r:SpecifiedLineTradeDelivery>
            <r:RequestedQuantity unitCode="H87">500</r:RequestedQuantity>
          </r:SpecifiedLineTradeDelivery>
          <r:SpecifiedLineTradeSettlement>
            <r:SpecifiedTradeSettlementLineMonetarySummation>
              <r:LineTotalAmount>50.00</r:LineTotalAmount>
            </r:SpecifiedTradeSettlementLineMonetarySummation>
          </r:SpecifiedLineTradeSettlement>
        </r:IncludedSupplyChainTradeLineItem>
        <r:ApplicableHeaderTradeAgreement>
          <r:BuyerReference>EINKAUF-1</r:BuyerReference>
          <r:SellerTradeParty><r:Name>Lieferant KG</r:Name></r:SellerTradeParty>
          <r:BuyerTradeParty>
            <r:Name>Besteller GmbH</r:Name>
            <r:PostalTradeAddress><r:CityName>Berlin</r:CityName></r:PostalTradeAddress>
          </r:BuyerTradeParty>
        </r:ApplicableHeaderTradeAgreement>
        <r:ApplicableHeaderTradeDelivery>
          <r:RequestedDeliverySupplyChainEvent>
            <r:OccurrenceDateTime><u:DateTimeString format="102">20260915</u:DateTimeString></r:OccurrenceDateTime>
          </r:RequestedDeliverySupplyChainEvent>
        </r:ApplicableHeaderTradeDelivery>
        <r:ApplicableHeaderTradeSettlement>
          <r:OrderCurrencyCode>EUR</r:OrderCurrencyCode>
          <r:SpecifiedTradeAllowanceCharge>
            <r:ChargeIndicator><u:Indicator>true</u:Indicator></r:ChargeIndicator>
            <r:ActualAmount>4.90</r:ActualAmount>
            <r:Reason>Versand</r:Reason>
          </r:SpecifiedTradeAllowanceCharge>
          <r:SpecifiedTradeSettlementHeaderMonetarySummation>
            <r:LineTotalAmount>50.00</r:LineTotalAmount>
            <r:GrandTotalAmount>65.33</r:GrandTotalAmount>
          </r:SpecifiedTradeSettlementHeaderMonetarySummation>
        </r:ApplicableHeaderTradeSettlement>
      </o:SupplyChainTradeTransaction>
    </o:SCRDMCCBDACIOMessageStructure>
    """

    /// Peppol-Bestellung (UBL Order).
    static let ublOrderXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Order xmlns="urn:oasis:names:specification:ubl:schema:xsd:Order-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:CustomizationID>urn:fdc:peppol.eu:poacc:trns:order:3</cbc:CustomizationID>
      <cbc:ProfileID>urn:fdc:peppol.eu:poacc:bis:ordering:3</cbc:ProfileID>
      <cbc:ID>PO-11</cbc:ID>
      <cbc:IssueDate>2026-09-01</cbc:IssueDate>
      <cbc:OrderTypeCode>220</cbc:OrderTypeCode>
      <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
      <cac:BuyerCustomerParty>
        <cac:Party><cac:PartyName><cbc:Name>Besteller GmbH</cbc:Name></cac:PartyName></cac:Party>
      </cac:BuyerCustomerParty>
      <cac:SellerSupplierParty>
        <cac:Party><cac:PartyName><cbc:Name>Lieferant KG</cbc:Name></cac:PartyName></cac:Party>
      </cac:SellerSupplierParty>
      <cac:AnticipatedMonetaryTotal>
        <cbc:PayableAmount currencyID="EUR">50.00</cbc:PayableAmount>
      </cac:AnticipatedMonetaryTotal>
      <cac:OrderLine>
        <cac:LineItem>
          <cbc:ID>1</cbc:ID>
          <cbc:Quantity unitCode="H87">500</cbc:Quantity>
          <cac:Item><cbc:Name>Schrauben M4</cbc:Name></cac:Item>
        </cac:LineItem>
      </cac:OrderLine>
    </Order>
    """

    /// Peppol-Bestellantwort (UBL OrderResponse).
    static let ublOrderResponseXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <OrderResponse xmlns="urn:oasis:names:specification:ubl:schema:xsd:OrderResponse-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:CustomizationID>urn:fdc:peppol.eu:poacc:trns:order_response:3</cbc:CustomizationID>
      <cbc:ID>AB-11</cbc:ID>
      <cbc:IssueDate>2026-09-02</cbc:IssueDate>
      <cbc:OrderResponseCode>AP</cbc:OrderResponseCode>
      <cac:OrderReference><cbc:ID>PO-11</cbc:ID></cac:OrderReference>
    </OrderResponse>
    """

    /// CII-Gutschrift (TypeCode 381, Factur-X BASIC) mit VOLLSTÄNDIGER und
    /// rechnerisch richtiger Summenkette: 100 − 5 + 3 = 98; 19 % = 18.62;
    /// 116.62 brutto = fällig. Grundlage für die Summenprüfungs-Tests.
    static let ciiCreditNoteXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rsm:CrossIndustryInvoice
      xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
      xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
      <rsm:ExchangedDocumentContext>
        <ram:GuidelineSpecifiedDocumentContextParameter>
          <ram:ID>urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic</ram:ID>
        </ram:GuidelineSpecifiedDocumentContextParameter>
      </rsm:ExchangedDocumentContext>
      <rsm:ExchangedDocument>
        <ram:ID>G-2026-3</ram:ID>
        <ram:TypeCode>381</ram:TypeCode>
        <ram:IssueDateTime><udt:DateTimeString format="102">20260902</udt:DateTimeString></ram:IssueDateTime>
      </rsm:ExchangedDocument>
      <rsm:SupplyChainTradeTransaction>
        <ram:IncludedSupplyChainTradeLineItem>
          <ram:AssociatedDocumentLineDocument><ram:LineID>1</ram:LineID></ram:AssociatedDocumentLineDocument>
          <ram:SpecifiedTradeProduct><ram:Name>Rückvergütung</ram:Name></ram:SpecifiedTradeProduct>
          <ram:SpecifiedLineTradeSettlement>
            <ram:SpecifiedTradeSettlementLineMonetarySummation>
              <ram:LineTotalAmount>100.00</ram:LineTotalAmount>
            </ram:SpecifiedTradeSettlementLineMonetarySummation>
          </ram:SpecifiedLineTradeSettlement>
        </ram:IncludedSupplyChainTradeLineItem>
        <ram:ApplicableHeaderTradeAgreement>
          <ram:SellerTradeParty><ram:Name>Verkäufer GmbH</ram:Name></ram:SellerTradeParty>
          <ram:BuyerTradeParty><ram:Name>Käufer AG</ram:Name></ram:BuyerTradeParty>
        </ram:ApplicableHeaderTradeAgreement>
        <ram:ApplicableHeaderTradeDelivery/>
        <ram:ApplicableHeaderTradeSettlement>
          <ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>
          <ram:ApplicableTradeTax>
            <ram:CalculatedAmount>18.62</ram:CalculatedAmount>
            <ram:TypeCode>VAT</ram:TypeCode>
            <ram:BasisAmount>98.00</ram:BasisAmount>
            <ram:CategoryCode>S</ram:CategoryCode>
            <ram:RateApplicablePercent>19</ram:RateApplicablePercent>
          </ram:ApplicableTradeTax>
          <ram:SpecifiedTradeAllowanceCharge>
            <ram:ChargeIndicator><udt:Indicator>false</udt:Indicator></ram:ChargeIndicator>
            <ram:ActualAmount>5.00</ram:ActualAmount>
          </ram:SpecifiedTradeAllowanceCharge>
          <ram:SpecifiedTradeAllowanceCharge>
            <ram:ChargeIndicator><udt:Indicator>true</udt:Indicator></ram:ChargeIndicator>
            <ram:ActualAmount>3.00</ram:ActualAmount>
          </ram:SpecifiedTradeAllowanceCharge>
          <ram:SpecifiedTradeSettlementHeaderMonetarySummation>
            <ram:LineTotalAmount>100.00</ram:LineTotalAmount>
            <ram:ChargeTotalAmount>3.00</ram:ChargeTotalAmount>
            <ram:AllowanceTotalAmount>5.00</ram:AllowanceTotalAmount>
            <ram:TaxBasisTotalAmount>98.00</ram:TaxBasisTotalAmount>
            <ram:TaxTotalAmount currencyID="EUR">18.62</ram:TaxTotalAmount>
            <ram:GrandTotalAmount>116.62</ram:GrandTotalAmount>
            <ram:DuePayableAmount>116.62</ram:DuePayableAmount>
          </ram:SpecifiedTradeSettlementHeaderMonetarySummation>
        </ram:ApplicableHeaderTradeSettlement>
      </rsm:SupplyChainTradeTransaction>
    </rsm:CrossIndustryInvoice>
    """

    /// Rechnung mit absichtlich falscher Summe: Bruttobetrag 120.00 statt
    /// 116.62 — BT-112 und BT-115 verletzen dann je eine Regel.
    static let ciiWrongSumXML = ciiCreditNoteXML.replacingOccurrences(
        of: "<ram:GrandTotalAmount>116.62</ram:GrandTotalAmount>",
        with: "<ram:GrandTotalAmount>120.00</ram:GrandTotalAmount>")

    /// Rechnung ohne Pflichtfelder: nur der Kontextblock, XRechnung-Profil
    /// (verlangt zusätzlich die Leitweg-ID BT-10).
    static let ciiMissingFieldsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rsm:CrossIndustryInvoice
      xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100">
      <rsm:ExchangedDocumentContext>
        <ram:GuidelineSpecifiedDocumentContextParameter>
          <ram:ID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</ram:ID>
        </ram:GuidelineSpecifiedDocumentContextParameter>
      </rsm:ExchangedDocumentContext>
      <rsm:ExchangedDocument/>
    </rsm:CrossIndustryInvoice>
    """
}
