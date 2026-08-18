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
for f in fo.xsl titlepages.xsl fop.xconf global.tmpl; do
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
check "the font directory is absolute" "yes" \
      "$(grep -qE '<directory>/' "$ENGINE/xsl/fop.xconf" && echo yes || echo no)"

# And they must point at what the Dockerfile actually installs.
check "the font directory is where the image puts it" "yes" \
      "$(grep -q '<directory>/engine/xsl/fonts</directory>' "$ENGINE/xsl/fop.xconf" &&
         grep -q 'COPY engines/pandoc-xslt/xsl *\/engine/xsl' "$ENGINE/Dockerfile" &&
         echo yes || echo no)"


echo "============ FONTS ============"
# Every family fo.xsl names must actually be present, or FOP substitutes
# silently. The check is deliberately on the family names in the stylesheet
# rather than a fixed list, so changing the design fails here rather than in a
# PDF nobody looks at closely.
for fam in Figtree NotoSansMono; do
	if grep -qiE "$(echo "$fam" | sed 's/NotoSansMono/Noto Sans Mono/')" "$ENGINE/xsl/fo.xsl"; then
		check "$fam is bundled" "yes" \
		      "$(ls "$ENGINE/xsl/fonts" 2>/dev/null | grep -qi "^$fam" && echo yes || echo no)"
	fi
done

# Licensing: only fonts that may be redistributed. AndaleMono (Monotype) and
# Frutiger (Linotype) both shipped in the 2015/2024 originals and must not be
# in the image; Figtree and Noto are SIL OFL.
check "no commercially-licensed fonts" "0" \
      "$(ls "$ENGINE/xsl/fonts" 2>/dev/null | grep -ciE 'andale|frutiger')"


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
      "$(grep -qE '^ARG FOP_VERSION=' "$ENGINE/Dockerfile" && echo yes || echo no)"
check "a checksum is pinned" "yes" \
      "$(grep -qE '^ARG FOP_SHA512=[0-9a-f]{128}$' "$ENGINE/Dockerfile" && echo yes || echo no)"
check "it is verified, not just downloaded" "yes" \
      "$(grep -q 'sha512sum -c' "$ENGINE/Dockerfile" && echo yes || echo no)"
check "from the permanent archive" "yes" \
      "$(grep -q 'archive.apache.org' "$ENGINE/Dockerfile" && echo yes || echo no)"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
