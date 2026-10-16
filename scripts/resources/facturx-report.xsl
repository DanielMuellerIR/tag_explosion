<?xml version="1.0" encoding="UTF-8"?>
<!-- MIT: Tag Explosion. Der importierte Apache-2.0-Bericht bleibt unverändert.
     Nichtfatale Schematron-Warnungen werden angezeigt, verhindern aber keinen
     Erfolg. Fehlende SVRL-Ausgabe und technische Fehler bleiben ablehnend. -->
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:in="http://www.xoev.de/de/validator/framework/1/createreportinput"
  xmlns:rep="http://www.xoev.de/de/validator/varl/1"
  xmlns:svrl="http://purl.oclc.org/dsdl/svrl"
  xmlns:s="http://www.xoev.de/de/validator/framework/1/scenarios" version="2.0">
  <xsl:import href="default-report.xsl"/>
  <xsl:template match="in:validationResultsSchematron">
    <xsl:variable name="step" select="concat('val-sch.', 1 + count(preceding-sibling::in:validationResultsSchematron))"/>
    <xsl:variable name="output" select="in:results/svrl:schematron-output"/>
    <xsl:variable name="messages" as="element(rep:message)*">
      <xsl:apply-templates select="$output/(svrl:failed-assert | svrl:successful-report)">
        <xsl:with-param name="parent-id" select="$step"/>
      </xsl:apply-templates>
    </xsl:variable>
    <rep:validationStepResult id="{$step}" valid="{exists($output) and empty($messages[@level = 'error'])}">
      <xsl:apply-templates select="s:resource" mode="copy"/>
      <xsl:sequence select="$messages"/>
      <xsl:if test="empty($output)">
        <rep:message id="{$step}.processing-error" level="error" code="PROCESSING_ERROR" xpathLocation="/">Die Schematron-Prüfung hat keinen SVRL-Bericht erzeugt.</rep:message>
      </xsl:if>
    </rep:validationStepResult>
  </xsl:template>
</xsl:stylesheet>
