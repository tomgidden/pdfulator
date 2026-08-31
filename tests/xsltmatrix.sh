#!/bin/sh
# The pandoc-xslt engine's assets.
#
# Not the rendering -- that needs pandoc, xsltproc, a JRE and FOP, which is
# what the image is for. What this checks is that the assets are *well formed*
# and internally consistent, which is cheap, needs nothing installed beyond
# xmllint, and catches the failures that are otherwise found only by a full
# image build followed by a container run.
#
# Written after two such round trips:
#
#   1. An XML comment containing "--" (legal in most languages, forbidden in
#      XML) made xsltproc fail with "Double hyphen within comment" -- after a
#      seven-minute image build.
#   2. Font paths in fop.xconf were relative to a layout the image does not
#      have, so every font silently fell back to Times. That one produced a
#      valid PDF and a clean exit, and was visible only by extracting the text.
#
# Both are static properties of the files. Neither should cost a build.
REPO=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=$REPO/engines/pandoc-xslt
FAIL=0

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

if ! command -v xmllint >/dev/null 2>&1; then
	echo "SKIP: xmllint not installed; xsltmatrix needs it."
	exit 0
fi


echo "============ WELL-FORMED ============"
# xsltproc rejects the whole stylesheet on any XML error, so a stray "--"
# inside a comment takes the engine down entirely.
for f in fo.xsl titlepages.xsl fop.xconf template.xml.pandoc; do
	check "$f is well-formed XML" "0" \
	      "$(xmllint --noout "$ENGINE/xsl/$f" >/dev/null 2>&1; echo $?)"
done

# The specific trap, checked by name because the error message
# ("Double hyphen within comment") does not obviously mean "your comment has a
# dash in it".
check "no double hyphens inside XML comments" "0" \
      "$(awk 'BEGIN{RS="-->"} /<!--/{ c=$0; sub(/.*<!--/,"",c); if (c ~ /--/) n++ } END{print n+0}' \
         "$ENGINE/xsl/fo.xsl")"


echo "============ FOP PATHS ============"
# fop.xconf's relative paths resolve against <base>, and <base> resolves
# against the *working directory* -- which render deliberately makes the
# scratch directory, because FOP writes .fop into the cwd and /engine is
# read-only. So these must be absolute, or the fonts are silently not found
# and every document renders in Times.
check "the config base is absolute" "yes" \
      "$(grep -qE '<base>/' "$ENGINE/xsl/fop.xconf" && echo yes || echo no)"


echo "============ FONTS ============"
# The engine bundles no fonts at all now, and its fop.xconf scans no directory.
# Both belong to the theme: the wrapper generates a fop-fonts.xconf with an
# explicit <font> per face and the engine prefers it (see render). A scanned
# directory took each face's weight from its own metadata, so a face declared
# 700 could register as 400 and the document silently lost its bold.
check "the engine bundles no fonts" "no" \
      "$([ -d "$ENGINE/xsl/fonts" ] && echo yes || echo no)"
# Matched with xmllint rather than grep: the word `directory` appears in the
# comment explaining why the element is absent, and a test that cannot tell an
# element from prose about it is a test that will lie in one direction or the
# other.
check "the shipped config scans no font directory" "0" \
      "$(xmllint --xpath 'count(//directory)' "$ENGINE/xsl/fop.xconf" 2>/dev/null || echo 0)"

# Every family fo.xsl names must be one FOP is certain to have, because these
# are only the fallbacks: a theme overrides them, and a theme that does not
# leaves these to render the document. Naming anything else here is how
# `Sabon` sat in the stylesheet for years with no font behind it.
for fam in $(sed -n 's/.*<xsl:param name="[a-z]*\.font\.family">\([^<]*\)<.*/\1/p' \
             "$ENGINE/xsl/fo.xsl" | sort -u); do
	case $fam in
		Times|Helvetica|Courier|Symbol|ZapfDingbats)
			check "the $fam fallback is a base-14 font" "yes" "yes" ;;
		*)
			check "the $fam fallback is a base-14 font" "yes" "no" ;;
	esac
done

# Licensing: only fonts that may be redistributed. AndaleMono (Monotype) and
# Frutiger (Linotype) both shipped in the 2015/2024 originals and must not
# come back with any theme the project ships.
check "no commercially-licensed fonts are shipped" "0" \
      "$(ls "$REPO/themes"/*/fonts 2>/dev/null | grep -ciE 'andale|frutiger')"


echo "============ BRANDING ============"
# The XSLT came from a client's house style. Their name and logo must not ship.
check "no Starberry references" "0" \
      "$(grep -rli 'starberry' "$ENGINE" 2>/dev/null | wc -l | tr -d ' ')"
check "the logo is pdfulator's" "yes" \
      "$([ -f "$ENGINE/xsl/images/pdfulator-logotype.svg" ] && echo yes || echo no)"

# "Confidential" was unconditional in the original: every document stamped,
# whether or not it was, which devalues the marking where it matters. It now
# comes from the document's own legalnotice.
check "the classification is conditional" "yes" \
      "$(grep -q '<xsl:if test="//legalnotice">' "$ENGINE/xsl/fo.xsl" && echo yes || echo no)"
check "and not hardcoded" "0" \
      "$(grep -c '<xsl:text>Confidential</xsl:text>' "$ENGINE/xsl/fo.xsl")"


echo "============ VENDORED FOP ============"
# Pinned by version and checksum. The 2015 Dockerfile's eu.apache.org URL is
# dead -- mirrors drop old releases -- so the archive is the only durable
# source, and a pinned checksum is what makes the fetch trustworthy.
check "a FOP version is pinned" "yes" \
      "$(grep -qE '^ARG FOP_VERSION=' "$ENGINE/_nopayload/Dockerfile" && echo yes || echo no)"
check "a checksum is pinned" "yes" \
      "$(grep -qE '^ARG FOP_SHA512=[0-9a-f]{128}$' "$ENGINE/_nopayload/Dockerfile" && echo yes || echo no)"
check "it is verified, not just downloaded" "yes" \
      "$(grep -q 'sha512sum -c' "$ENGINE/_nopayload/Dockerfile" && echo yes || echo no)"
check "from the permanent archive" "yes" \
      "$(grep -q 'archive.apache.org' "$ENGINE/_nopayload/Dockerfile" && echo yes || echo no)"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
