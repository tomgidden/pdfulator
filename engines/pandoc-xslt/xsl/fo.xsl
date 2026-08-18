<?xml version='1.0'?>
<xsl:stylesheet version="1.1" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:fo="http://www.w3.org/1999/XSL/Format"
  xmlns:d="http://docbook.org/ns/docbook"
  xmlns:fox="http://xmlgraphics.apache.org/fop/extensions">

  <xsl:import href="http://docbook.sourceforge.net/release/xsl/current/fo/docbook.xsl" />

  <xsl:import href="./titlepages.xsl" />

  <xsl:param name="hyphenate">false</xsl:param>

  <xsl:param name="L">18</xsl:param>

  <xsl:param name="draft.mode">no</xsl:param>
  <xsl:param name="draft.watermark.image">images/draft.png</xsl:param>

  <!--
  <xsl:param name="column.count.body">2</xsl:param>
  <xsl:param name="column.gap.body">3em</xsl:param>
  <xsl:param name="body.start.indent">0pt</xsl:param>
-->

  <!--
      <xsl:param name="variablelist.as.blocks" select="1" />
  -->

  <xsl:param name="serif.font.family">Sabon</xsl:param>
  <xsl:param name="sans.font.family">Figtree</xsl:param>
  <xsl:param name="dingbat.font.family">Figtree</xsl:param>
  <xsl:param name="monospace.font.family">Noto Sans Mono Condensed</xsl:param>

  <xsl:param name="body.font.family"><xsl:value-of select="$sans.font.family" /></xsl:param>
  <xsl:param name="body.font.weight">400</xsl:param>
  <xsl:param name="body.font.master">12</xsl:param>
  <xsl:param name="line-height"><xsl:value-of select="$L" />pt</xsl:param>

  <xsl:param name="title.font.family"><xsl:value-of select="$sans.font.family" /></xsl:param>
  <xsl:param name="title.fontset"><xsl:value-of select="$sans.font.family" /></xsl:param>

  <xsl:param name="alignment">start</xsl:param>

  <!--
  <xsl:param name="alignment">justify</xsl:param>
  <xsl:template match="para[1]">
    <fo:block text-indent="0em">
      <xsl:apply-imports/>
    </fo:block>
  </xsl:template>
  <xsl:template match="para">
    <fo:block text-indent="1em">
      <xsl:apply-imports/>
    </fo:block>
  </xsl:template>
-->

  <!-- Fix for monospace fonts being too damn tall -->
  <xsl:attribute-set name="normal.para.spacing" use-attribute-sets="one-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <!-- <xsl:param name="body.start.indent">0.5in</xsl:param> -->

  <xsl:param name="formal.title.placement"> figure after example after equation after table after
    procedure after </xsl:param>

  <xsl:attribute-set name="formal.title.properties" use-attribute-sets="one-spacing">
    <xsl:attribute name="font-family"><xsl:value-of select="$sans.font.family" /></xsl:attribute>
    <xsl:attribute name="font-weight">bold</xsl:attribute>
    <xsl:attribute name="text-align">center</xsl:attribute>
    <xsl:attribute name="hyphenate">false</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="nongraphical.admonition.properties" use-attribute-sets="one-spacing">
    <xsl:attribute name="padding"><xsl:value-of select="$line-height" /></xsl:attribute>
    <xsl:attribute name="margin-{$direction.align.start}">-4pc</xsl:attribute>
    <xsl:attribute name="margin-{$direction.align.end}">0in</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="list.block.properties" use-attribute-sets="zero-spacing.before zero-spacing.after">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>

  </xsl:attribute-set>

  <xsl:attribute-set name="list.item.spacing" use-attribute-sets="half-spacing.before half-spacing.after">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <!-- <xsl:attribute name="border">1pt solid #0f0</xsl:attribute> -->
  </xsl:attribute-set>

  <xsl:attribute-set name="compact.list.item.spacing">
  <xsl:attribute name="space-before.optimum">0</xsl:attribute>
  <xsl:attribute name="space-before.minimum">0</xsl:attribute>
  <xsl:attribute name="space-before.maximum">0</xsl:attribute>
</xsl:attribute-set>

  <xsl:attribute-set name="list.block.spacing" use-attribute-sets="zero-spacing.before zero-spacing.after">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <!-- <xsl:attribute name="border">1pt solid #f0f</xsl:attribute> -->
  </xsl:attribute-set>

  <xsl:attribute-set name="orderedlist.properties" use-attribute-sets="zero-spacing.before zero-spacing.after">
    <!-- <xsl:attribute name="border">1pt solid #f70</xsl:attribute> -->
  </xsl:attribute-set>

  <xsl:attribute-set name="itemizedlist.properties" use-attribute-sets="zero-spacing.before zero-spacing.after">
    <!-- <xsl:attribute name="border">1pt solid #00f</xsl:attribute> -->
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:param name="email.mailto.enabled" select="1"></xsl:param>

  <xsl:param name="double.sided">0</xsl:param>

  <!--
      <xsl:attribute-set name="section.level1.properties">
      <xsl:attribute name="break-before">page</xsl:attribute>
      </xsl:attribute-set>
-->

  <xsl:attribute-set name="table.table.properties">
    <xsl:attribute name="font-family"><xsl:value-of select="$sans.font.family" /></xsl:attribute>
  </xsl:attribute-set>

  <xsl:param name="table.frame.border.thickness">1.5pt</xsl:param>
  <xsl:param name="table.frame.border.color">#999</xsl:param>
  <xsl:param name="table.cell.border.thickness">1.5pt</xsl:param>
  <xsl:param name="table.cell.border.color">#999</xsl:param>


  <xsl:param name="highlight.source" select="1" />


  <!-- Spacing macros to reset grid alignment to zero -->

  <xsl:attribute-set name="zero-spacing" use-attribute-sets="zero-spacing.before zero-spacing.after">
  </xsl:attribute-set>

  <xsl:attribute-set name="zero-spacing.before">
    <xsl:attribute name="space-before.minimum">0</xsl:attribute>
    <xsl:attribute name="space-before.optimum">0</xsl:attribute>
    <xsl:attribute name="space-before.maximum">0</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="zero-spacing.after">
    <xsl:attribute name="space-after.minimum">0</xsl:attribute>
    <xsl:attribute name="space-after.optimum">0</xsl:attribute>
    <xsl:attribute name="space-after.maximum">0</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="half-spacing" use-attribute-sets="half-spacing.before half-spacing.after">
  </xsl:attribute-set>

  <xsl:attribute-set name="half-spacing.before">
    <xsl:attribute name="line-stacking-strategy">line-height</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="0.5*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="0.5*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="0.5*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="half-spacing.after">
    <xsl:attribute name="line-stacking-strategy">line-height</xsl:attribute>
    <xsl:attribute name="space-after.minimum"><xsl:value-of select="0.5*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-after.optimum"><xsl:value-of select="0.5*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-after.maximum"><xsl:value-of select="0.5*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="one-spacing" use-attribute-sets="one-spacing.before one-spacing.after">
  </xsl:attribute-set>

  <xsl:attribute-set name="one-spacing.before">
    <xsl:attribute name="line-stacking-strategy">line-height</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="$line-height" /></xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="$line-height" /></xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="$line-height" /></xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="one-spacing.after">
    <xsl:attribute name="line-stacking-strategy">line-height</xsl:attribute>
    <xsl:attribute name="space-after.minimum"><xsl:value-of select="$line-height" /></xsl:attribute>
    <xsl:attribute name="space-after.optimum"><xsl:value-of select="$line-height" /></xsl:attribute>
    <xsl:attribute name="space-after.maximum"><xsl:value-of select="$line-height" /></xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="two-spacing" use-attribute-sets="two-spacing.before two-spacing.after">
  </xsl:attribute-set>

  <xsl:attribute-set name="two-spacing.before">
    <xsl:attribute name="line-stacking-strategy">line-height</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="two-spacing.after">
    <xsl:attribute name="line-stacking-strategy">line-height</xsl:attribute>
    <xsl:attribute name="space-after.minimum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-after.optimum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-after.maximum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
  </xsl:attribute-set>


  <!-- Document title and front matter (author, date, etc.) -->

  <xsl:attribute-set name="component.title.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="text-align">start</xsl:attribute>
    <xsl:attribute name="font-size">24pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <xsl:attribute name="font-weight">bold</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="component.titlepage.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="font-family"><xsl:value-of select="$title.font.family" /></xsl:attribute>
    <xsl:attribute name="text-align">start</xsl:attribute>
    <xsl:attribute name="font-size">12pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:template match="revhistory" mode="titlepage.mode">
    <!-- No revision history -->
  </xsl:template>

  <xsl:attribute-set name="productname.titlepage.properties">
    <xsl:attribute name="font-family"><xsl:value-of select="$title.font.family" /></xsl:attribute>
  </xsl:attribute-set>

  <xsl:template match="productname" mode="article.titlepage.recto.auto.mode">
    <fo:block
      xsl:use-attribute-sets="article.titlepage.recto.style productname.titlepage.properties">
    Project: <xsl:apply-templates select="." mode="article.titlepage.recto.mode" />
    </fo:block>
  </xsl:template>

  <!-- Headings -->

  <xsl:attribute-set name="section.title.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="font-family"><xsl:value-of select="$title.font.family" /></xsl:attribute>
    <xsl:attribute name="font-weight">normal</xsl:attribute>
    <xsl:attribute name="keep-with-next.within-column">always</xsl:attribute>
    <xsl:attribute name="text-align">start</xsl:attribute>
    <xsl:attribute name="start-indent"><xsl:value-of select="$body.start.indent" /></xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.level1.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.level1.first.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:template match="sect1[1]">
    <xsl:element name="fo:{$section.container.element}"
      use-attribute-sets="section.level1.first.properties">
      <xsl:attribute name="id"><xsl:call-template name="object.id" /></xsl:attribute>
      <xsl:call-template
        name="section.content" />
    </xsl:element>
  </xsl:template>
    
  <xsl:attribute-set name="section.title.level1.properties" use-attribute-sets="zero-spacing.after">
    <xsl:attribute name="start-indent"><xsl:value-of select="$title.margin.left" /></xsl:attribute>
    <xsl:attribute name="font-size">24pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.title.level2.properties" use-attribute-sets="zero-spacing.after">
    <xsl:attribute name="start-indent"><xsl:value-of select="$title.margin.left" /></xsl:attribute>
    <xsl:attribute name="font-size">20pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.title.level3.properties" use-attribute-sets="zero-spacing.after">
    <xsl:attribute name="font-size">18pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="2*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="2*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.title.level4.properties" use-attribute-sets="zero-spacing.after">
    <xsl:attribute name="font-size">16pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="0*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="0*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.title.level5.properties" use-attribute-sets="zero-spacing.after">
    <xsl:attribute name="font-weight">200</xsl:attribute>
    <xsl:attribute name="font-size">14pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="0*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="0*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.title.level6.properties" use-attribute-sets="zero-spacing.after">
    <xsl:attribute name="font-weight">200</xsl:attribute>
    <xsl:attribute name="font-size">12pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.minimum"><xsl:value-of select="0*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.optimum"><xsl:value-of select="0*$L" />pt</xsl:attribute>
    <xsl:attribute name="space-before.maximum"><xsl:value-of select="1*$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:attribute-set name="section.level1.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>
  <xsl:attribute-set name="section.level2.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>
  <xsl:attribute-set name="section.level3.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>
  <xsl:attribute-set name="section.level4.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>
  <xsl:attribute-set name="section.level5.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>
  <xsl:attribute-set name="section.level6.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
  </xsl:attribute-set>

  <!-- Admonitions -->

  <xsl:attribute-set name="admonition.title.properties" use-attribute-sets="normal.para.spacing">
    <xsl:attribute name="font-family"><xsl:value-of select="$title.font.family" /></xsl:attribute>
    <xsl:attribute name="font-weight">normal</xsl:attribute>
    <xsl:attribute name="keep-with-next.within-column">always</xsl:attribute>
  </xsl:attribute-set>


  <!-- Links -->

  <xsl:attribute-set name="xref.properties">
    <xsl:attribute name="font-family"><xsl:value-of select="$sans.font.family" /></xsl:attribute>
    <xsl:attribute name="font-style">italic</xsl:attribute>
    <xsl:attribute name="font-weight">200</xsl:attribute>
    <xsl:attribute name="wrap-option">no-wrap</xsl:attribute>
    <!--    <xsl:attribute name="text-decoration">underline</xsl:attribute> -->
    <xsl:attribute name="keep-together.within-line">always</xsl:attribute>
    <xsl:attribute name="hyphenate">false</xsl:attribute>
  </xsl:attribute-set>


  <!-- Footnotes -->

  <xsl:attribute-set name="footnote.properties">
    <xsl:attribute name="padding-top"><xsl:value-of select="$line-height" /></xsl:attribute>
  </xsl:attribute-set>

  <xsl:param name="footnote.number.symbols">&#x2020;&#x2021;*123456789</xsl:param>

  <xsl:attribute-set name="footnote.sep.leader.properties">
    <xsl:attribute name="color">#ccc</xsl:attribute>
    <xsl:attribute name="leader-pattern">rule</xsl:attribute>
    <xsl:attribute name="leader-length">1in</xsl:attribute>
  </xsl:attribute-set>


  <!-- Code blocks -->

  <!-- 
    <xsl:param name="monospace.font.weight">400</xsl:param>
  <xsl:param name="monospace.verbatim.font.weight">400</xsl:param>
  <xsl:param name="monospace.verbatim.font.width">0.2em</xsl:param>
-->
  

  <xsl:attribute-set name="monospace.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="font-size">10pt</xsl:attribute>
    <xsl:attribute name="font-weight">400</xsl:attribute>
    <xsl:attribute name="hyphenate">false</xsl:attribute>
    <xsl:attribute name="white-space-collapse">false</xsl:attribute>
    <xsl:attribute name="white-space-treatment">preserve</xsl:attribute>
    <!-- <xsl:attribute name="linefeed-treatment">preserve</xsl:attribute> -->
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <!-- <xsl:attribute name="padding">2pt</xsl:attribute> -->
    <xsl:attribute name="background-color">#f7f7f7</xsl:attribute>
    <xsl:attribute name="wrap-option">no-wrap</xsl:attribute>
  </xsl:attribute-set>
  
  <xsl:attribute-set name="monospace.verbatim.properties" use-attribute-sets="zero-spacing">
  </xsl:attribute-set>

  <xsl:attribute-set name="verbatim.properties" use-attribute-sets="zero-spacing">
    <xsl:attribute name="font-size">9pt</xsl:attribute>
    <xsl:attribute name="line-height"><xsl:value-of select="$L" />pt</xsl:attribute>
    <!-- hack compensate for Markdown -> Docbook adding in an extra line at the top -->
    <!-- <xsl:attribute name="padding-before">-<xsl:value-of select="$L" />pt</xsl:attribute> -->
    <!-- <xsl:attribute name="padding-before"><xsl:value-of select="$body.font.master * -1.25" />pt</xsl:attribute>  -->
  </xsl:attribute-set>

  <xsl:param name="shade.verbatim" select="1"></xsl:param> 
  <xsl:attribute-set name="shade.verbatim.style">
    <xsl:attribute name="background-color">#f7f7f7</xsl:attribute>
    <xsl:attribute name="border">0.5pt solid #999</xsl:attribute>
    <xsl:attribute name="fox:border-radius">2pt</xsl:attribute>
  </xsl:attribute-set>




  <!-- Page layout -->

  <xsl:param name="paper.type">A4</xsl:param>
  <xsl:param name="body.margin.top">0.5in</xsl:param>
  <xsl:param name="body.margin.bottom">0.5in</xsl:param>

  <xsl:output indent="yes" />

  <xsl:param name="xref.with.number.and.title" select="0" />

  <xsl:param name="insert.xref.page.number">no</xsl:param>

  <xsl:param name="fop1.extensions">1</xsl:param>


  <!-- Page footers -->
  <xsl:param name="footer.column.widths">10 0 1</xsl:param>

  <xsl:param name="footer.rule" select="0"></xsl:param>

  <xsl:template name="foot.sep.rule">
    <xsl:param name="pageclass" />
    <xsl:param name="sequence" />
    <xsl:param name="gentext-key" />
    <xsl:if
      test="$footer.rule != 0">
      <xsl:attribute name="border-top-width">2pt</xsl:attribute>
      <xsl:attribute
        name="border-top-style">solid</xsl:attribute>
      <xsl:attribute name="border-top-color">#999</xsl:attribute>
    </xsl:if>
  </xsl:template>

  <xsl:attribute-set name="footer.content.properties">
    <xsl:attribute name="font-family"><xsl:value-of select="$title.fontset" /></xsl:attribute>
    <xsl:attribute name="font-size">10pt</xsl:attribute>
  </xsl:attribute-set>

  <xsl:template name="footer.content">
    <xsl:param name="pageclass" select="''" />
    <xsl:param name="sequence" select="''" />
    <xsl:param
      name="position" select="''" />
    <xsl:param name="gentext-key" select="''" />

    <xsl:choose>
      <xsl:when test="$position = 'left'">
        <xsl:apply-templates select="//copyright[1]" mode="titlepage.mode" />
        <!-- The classification, when the document declares one.
             This was an unconditional "Confidential" in the original
             stylesheet: right for one company's house style, wrong for a
             general tool, since every document produced would be stamped
             Confidential whether or not it was — which devalues the
             marking on the documents that actually need it. It now comes
             from `legalnotice` in the front matter, so a document says
             what it is and an unmarked one stays unmarked. -->
        <xsl:if test="//legalnotice">
          <xsl:text>  |  </xsl:text>
          <xsl:value-of select="normalize-space(//legalnotice[1])" />
        </xsl:if>
        <xsl:if
          test="//productname">
          <xsl:text> | </xsl:text>
          <xsl:value-of select="//productname" />
        </xsl:if>
        <!--        <xsl:apply-templates select="//pubdate[1]" mode="titlepage.mode" />-->
      </xsl:when>

      <xsl:when test="$position = 'right'">
        <fo:page-number />
      </xsl:when>
    </xsl:choose>
  </xsl:template>


  <!-- Page headers -->

  <xsl:param name="header.rule" select="0"></xsl:param>

  <xsl:param name="header.image.filename">images/pdfulator-logotype.svg</xsl:param>

  <xsl:template name="header.content">
    <xsl:param name="pageclass" select="''" />
    <xsl:param name="sequence" select="''" />
    <xsl:param
      name="position" select="''" />
    <xsl:param name="gentext-key" select="''" />
    <xsl:choose>
      <xsl:when test="$position = 'right'">
        <fo:external-graphic content-height="1.25em" baseline-shift="0.25em">
          <xsl:attribute name="src">
            <xsl:call-template name="fo-external-image">
              <xsl:with-param name="filename" select="$header.image.filename" />
            </xsl:call-template>
          </xsl:attribute>
        </fo:external-graphic>
      </xsl:when>
    </xsl:choose>
  </xsl:template>


  <!-- Table of contents (for book) -->

  <xsl:param name="toc.section.depth" select="0"></xsl:param>

  <xsl:param name="generate.toc"> article nop book toc,title </xsl:param>

  <xsl:param name="toc.indent.width"><xsl:value-of select="$title.margin.left" /></xsl:param>

  <xsl:attribute-set name="toc.line.properties">
    <xsl:attribute name="font-family"><xsl:value-of select="$sans.font.family" /></xsl:attribute>
  </xsl:attribute-set>


  <xsl:template name="object.id">
    <xsl:param name="object" select="." />

  <xsl:variable name="id" select="@id" />
  <xsl:variable
      name="xid" select="@xml:id" />

  <xsl:variable name="preceding.id"
      select="count(preceding::*[@id = $id])" />

  <xsl:variable name="preceding.xid"
      select="count(preceding::*[@xml:id = $xid])" />

  <xsl:choose>
      <xsl:when test="$object/@id and $preceding.id != 0">
        <xsl:value-of select="concat($object/@id, $preceding.id)" />
      </xsl:when>
      <xsl:when test="$object/@id">
        <xsl:value-of select="$object/@id" />
      </xsl:when>
      <xsl:when test="$object/@xml:id and $preceding.xid != 0">
        <xsl:value-of select="concat($object/@xml:id, $preceding.xid)" />
      </xsl:when>
      <xsl:when test="$object/@xml:id">
        <xsl:value-of select="$object/@xml:id" />
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="generate-id($object)" />
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>


  <!--
  <xsl:template match="article">
    <xsl:variable name="id">
      <xsl:call-template name="object.id" />
    </xsl:variable>

    <xsl:variable name="master-reference">
      <xsl:call-template name="select.pagemaster" />
    </xsl:variable>

    <fo:page-sequence hyphenate="{$hyphenate}"
                      master-reference="{$master-reference}">
      <xsl:attribute name="language">
        <xsl:call-template name="l10n.language" />
      </xsl:attribute>
      <xsl:attribute name="format">
        <xsl:call-template name="page.number.format">
          <xsl:with-param name="master-reference"
                          select="$master-reference" />
        </xsl:call-template>
      </xsl:attribute>
      <xsl:attribute name="initial-page-number">
        <xsl:call-template name="initial.page.number">
          <xsl:with-param name="master-reference"
                          select="$master-reference" />
        </xsl:call-template>
      </xsl:attribute>

      <xsl:attribute name="force-page-count">
        <xsl:call-template name="force.page.count">
          <xsl:with-param name="master-reference"
                          select="$master-reference" />
        </xsl:call-template>
      </xsl:attribute>

      <xsl:attribute name="hyphenation-character">
        <xsl:call-template name="gentext">
          <xsl:with-param name="key" select="'hyphenation-character'" />
        </xsl:call-template>
      </xsl:attribute>

      <xsl:attribute name="hyphenation-push-character-count">
        <xsl:call-template name="gentext">
          <xsl:with-param name="key"
                          select="'hyphenation-push-character-count'" />
        </xsl:call-template>
      </xsl:attribute>

      <xsl:attribute name="hyphenation-remain-character-count">
        <xsl:call-template name="gentext">
          <xsl:with-param name="key"
                          select="'hyphenation-remain-character-count'" />
        </xsl:call-template>
      </xsl:attribute>

      <xsl:apply-templates select="." mode="running.head.mode">
        <xsl:with-param name="master-reference" select="$master-reference" />
      </xsl:apply-templates>

      <xsl:apply-templates select="." mode="running.foot.mode">
        <xsl:with-param name="master-reference" select="$master-reference" />
      </xsl:apply-templates>

      <fo:flow flow-name="xsl-region-body">
        <xsl:call-template name="set.flow.properties">
          <xsl:with-param name="element" select="local-name(.)" />
          <xsl:with-param name="master-reference"
                          select="$master-reference" />
        </xsl:call-template>

        <fo:block id="{$id}" span="all" space-after.conditionality="retain" space-after="3em">
          <xsl:call-template name="article.titlepage" />
        </fo:block>

        <xsl:variable name="toc.params">
          <xsl:call-template name="find.path.params">
            <xsl:with-param name="table"
                            select="normalize-space($generate.toc)" />
          </xsl:call-template>
        </xsl:variable>

        <xsl:if test="contains($toc.params, 'toc')">
          <xsl:call-template name="component.toc">
            <xsl:with-param name="toc.title.p"
                            select="contains($toc.params, 'title')" />
          </xsl:call-template>
          <xsl:call-template name="component.toc.separator" />
        </xsl:if>

        <xsl:apply-templates/>
      </fo:flow>

    </fo:page-sequence>
  </xsl:template>
  -->

  <xsl:template match="copyright" mode="titlepage.mode">
    <!--
        <xsl:call-template name="gentext">
        <xsl:with-param name="key" select="'Copyright'" />
        </xsl:call-template>
        <xsl:call-template name="gentext.space" />
    -->
    <xsl:call-template name="dingbat">
      <xsl:with-param name="dingbat">copyright</xsl:with-param>
    </xsl:call-template>

    <xsl:call-template
      name="gentext.space" />

    <xsl:call-template name="copyright.years">
      <xsl:with-param name="years" select="year" />
      <xsl:with-param name="print.ranges" select="$make.year.ranges" />
      <xsl:with-param name="single.year.ranges" select="$make.single.year.ranges" />
    </xsl:call-template>

    <xsl:call-template
      name="gentext.space" />
    <xsl:apply-templates select="holder" mode="titlepage.mode" />
  </xsl:template>

  <xsl:template match="abstract" mode="titlepage.mode">
    <fo:block space-after.conditionality="retain" text-align="start" space-after="3em" span="all">
      <xsl:call-template name="formal.object.heading">
        <xsl:with-param name="title">
          <xsl:apply-templates select="." mode="title.markup" />
        </xsl:with-param>
      </xsl:call-template>
      <xsl:apply-templates mode="titlepage.mode" />
    </fo:block>
  </xsl:template>

  <xsl:param name="singlequote">
    <xsl:text>'</xsl:text>
  </xsl:param>
  <xsl:param name="curlyquote">
    <xsl:text>&#x2019;</xsl:text>
  </xsl:param>
  <xsl:param name="triplehyphen">
    <xsl:text>---</xsl:text>
  </xsl:param>
  <xsl:param name="emdash">
    <xsl:text>&#x2014;</xsl:text>
  </xsl:param>
  <xsl:param name="doublehyphen">
    <xsl:text>--</xsl:text>
  </xsl:param>
  <xsl:param name="endash">
    <xsl:text>&#x2013;</xsl:text>
  </xsl:param>

  <xsl:template match="para/text() | title/text()">
    <xsl:value-of select="translate(.,$singlequote,$curlyquote)" />
  </xsl:template>
  <!--
  <xsl:template match="para/text() | title/text()">
    <xsl:value-of select="replace(.,$triplehyphen,$emdash)" />
  </xsl:template>
  <xsl:template match="para/text() | title/text()">
    <xsl:value-of select="replace(.,$doublehyphen,$endash)" />
  </xsl:template>
-->


</xsl:stylesheet>