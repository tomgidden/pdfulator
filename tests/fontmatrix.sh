#!/bin/sh
# Font specification matrix.
#
# A theme declares fonts by role, and three unrelated targets are generated
# from that one declaration: CSS @font-face, a FOP font configuration, and
# XSL parameters. These cases pin the declaration's meaning -- what a merge
# does, what an inherited role is, what happens when a font is not there.
#
# The refusals are the point of the whole design. A font named in one place and
# absent from another is how a document renders in Times for years without
# anyone noticing; every path that could do that quietly is checked here to
# make sure it says so instead.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/conf.sh"
. "$LIB/paths.sh"
. "$LIB/theme.sh"
. "$LIB/fonts.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-fontmatrix
FAIL=0

trap 'rm -rf "$BASE"' EXIT INT TERM

ok() {  # ok <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' \
			"$1" "$2" "$3"
		FAIL=1
	fi
}

section() { printf '\n============ %s ============\n' "$1"; }


# A font file that is a real file but not a real font: nothing here parses
# one, and a 1.7MB variable font in a fixture is 1.7MB of nothing to see.
fakefont() {  # fakefont <path>
	mkdir -p -- "$(dirname -- "$1")"
	printf 'not really a font\n' > "$1"
}

setup() {
	rm -rf "$BASE"
	mkdir -p "$BASE/home" "$BASE/themes" "$BASE/stage/fonts"
	PDFULATOR_HOME="$BASE/home"
	PDFULATOR_DIR="$BASE"
	BUILTIN_THEME="$BASE/theme"
	unset PDFULATOR_FONT_FALLBACK
}


section "READING"

setup
mkdir -p "$BASE/themes/one"
cat > "$BASE/themes/one/fonts.conf" <<'EOF'
# a comment, and a blank line follow

body.family   = EB Garamond
body.source   = local
body.face.400.normal.file = fonts/eb-regular.otf
body.face.700.normal.file = fonts/eb-bold.otf
body.face.400.italic.file = fonts/eb-italic.otf
mono.family = Noto Sans Mono
mono.source = none
EOF

ok "a value is read" "EB Garamond" \
	"$(conf_get "$BASE/themes/one/fonts.conf" body.family)"
ok "whitespace around = is ignored" "local" \
	"$(conf_get "$BASE/themes/one/fonts.conf" body.source)"
ok "roles are found" "body mono" \
	"$(fonts_roles "$BASE/themes/one/fonts.conf" | tr '\n' ' ' | sed 's/ $//')"
ok "faces are found, deduplicated" "400 normal|700 normal|400 italic" \
	"$(fonts_faces "$BASE/themes/one/fonts.conf" body | tr '\n' '|' | sed 's/|$//')"
ok "a role with no faces has none" "" \
	"$(fonts_faces "$BASE/themes/one/fonts.conf" mono)"


section "MERGING"

# The case the whole cascade exists for: a child that changes only its body
# font must inherit the rest untouched, so that a theme can be one short file.
setup
mkdir -p "$BASE/themes/parent" "$BASE/themes/child"
cat > "$BASE/themes/parent/fonts.conf" <<'EOF'
body.family = Parent Serif
body.source = none
heading.family = Parent Sans
heading.source = none
mono.family = Parent Mono
mono.source = none
EOF
cat > "$BASE/themes/child/fonts.conf" <<'EOF'
body.family = Child Serif
body.source = none
EOF

fonts_merge "$BASE/merged" \
	"$BASE/themes/parent/fonts.conf" "$BASE/themes/child/fonts.conf"

ok "the child's role wins" "Child Serif" \
	"$(fonts_merged_get "$BASE/merged" body.family)"
ok "an unmentioned role is inherited" "Parent Sans" \
	"$(fonts_merged_get "$BASE/merged" heading.family)"
ok "and so is another" "Parent Mono" \
	"$(fonts_merged_get "$BASE/merged" mono.family)"
ok "every role is present once" "body heading mono" \
	"$(fonts_merged_roles "$BASE/merged" | sort | tr '\n' ' ' | sed 's/ $//')"

# The merged file must contain the winning role *once*, not both copies with
# the loser after it. Readers take the first match, so a merge that simply
# concatenated would still answer every question above correctly while leaving
# the parent's keys in the file -- and the next reader to iterate rather than
# look up would see the role twice.
ok "the losing copy is not left in the file" "1" \
	"$(grep -c 'body\.family' "$BASE/merged")"
ok "nor its value" "" \
	"$(grep 'Parent Serif' "$BASE/merged")"

# A role is replaced wholesale, not merged key by key: a child naming a new
# family without naming faces must not inherit the parent's *files*, which
# would pair a new name with the old glyphs.
cat > "$BASE/themes/parent/fonts.conf" <<'EOF'
body.family = Parent Serif
body.source = local
body.face.400.normal.file = fonts/parent.otf
EOF
cat > "$BASE/themes/child/fonts.conf" <<'EOF'
body.family = Child Serif
body.source = none
EOF
fonts_merge "$BASE/merged2" \
	"$BASE/themes/parent/fonts.conf" "$BASE/themes/child/fonts.conf"
ok "a replaced role keeps none of the parent's faces" "" \
	"$(fonts_merged_faces "$BASE/merged2" body)"

# A local path must stay relative to the file that declared it, even after the
# merge has combined files from different directories.
setup
mkdir -p "$BASE/themes/a" "$BASE/themes/b"
cat > "$BASE/themes/a/fonts.conf" <<'EOF'
mono.family = A Mono
mono.source = local
mono.face.400.normal.file = fonts/a.otf
EOF
cat > "$BASE/themes/b/fonts.conf" <<'EOF'
body.family = B Serif
body.source = local
body.face.400.normal.file = fonts/b.otf
EOF
fonts_merge "$BASE/merged3" \
	"$BASE/themes/a/fonts.conf" "$BASE/themes/b/fonts.conf"
ok "each role remembers its own directory" "$BASE/themes/a" \
	"$(fonts_merged_dir "$BASE/merged3" mono.face.400.normal.file)"
ok "and the other one too" "$BASE/themes/b" \
	"$(fonts_merged_dir "$BASE/merged3" body.face.400.normal.file)"


section "ACQUIRING"

setup
mkdir -p "$BASE/themes/local"
fakefont "$BASE/themes/local/fonts/real.otf"
cat > "$BASE/themes/local/fonts.conf" <<'EOF'
body.family = Real Font
body.source = local
body.face.400.normal.file = fonts/real.otf
EOF
fonts_merge "$BASE/m" "$BASE/themes/local/fonts.conf"

out=$(fonts_acquire "$BASE/m" body 400 normal "$BASE/stage/fonts")
ok "a local face is staged" "real-font-400-normal.otf" "$out"
ok "and the file is really there" "yes" \
	"$([ -f "$BASE/stage/fonts/real-font-400-normal.otf" ] && echo yes || echo no)"

# The Sabon case: named, absent, and until now silently rendered as Times.
cat > "$BASE/themes/local/fonts.conf" <<'EOF'
body.family = Sabon
body.source = local
body.face.400.normal.file = fonts/Sabon.otf
EOF
fonts_merge "$BASE/m2" "$BASE/themes/local/fonts.conf"

err=$(fonts_acquire "$BASE/m2" body 400 normal "$BASE/stage/fonts" 2>&1); st=$?
ok "a missing font fails" "1" "$st"
ok "the error names the role" "yes" \
	"$(printf '%s' "$err" | grep -q 'role:.*body' && echo yes || echo no)"
ok "the error names the font" "yes" \
	"$(printf '%s' "$err" | grep -q 'Sabon' && echo yes || echo no)"
ok "the error names the source" "yes" \
	"$(printf '%s' "$err" | grep -q 'local' && echo yes || echo no)"
ok "the error offers the way out" "yes" \
	"$(printf '%s' "$err" | grep -q -- '--font-fallback' && echo yes || echo no)"

PDFULATOR_FONT_FALLBACK=1
err=$(fonts_acquire "$BASE/m2" body 400 normal "$BASE/stage/fonts" 2>&1); st=$?
ok "--font-fallback continues instead" "0" "$st"
ok "and says so" "yes" \
	"$(printf '%s' "$err" | grep -q 'Warning' && echo yes || echo no)"
unset PDFULATOR_FONT_FALLBACK

cat > "$BASE/themes/local/fonts.conf" <<'EOF'
body.family = Whatever
body.source = google
EOF
fonts_merge "$BASE/m3" "$BASE/themes/local/fonts.conf"
err=$(fonts_acquire "$BASE/m3" body 400 normal "$BASE/stage/fonts" 2>&1); st=$?
ok "an unknown source fails" "1" "$st"
ok "and names what it expected" "yes" \
	"$(printf '%s' "$err" | grep -q 'local, url or none' && echo yes || echo no)"


section "CHECKSUMS"

# These cases fetch over file://, which needs curl or wget -- a stock debian:12
# has neither. Skipped rather than failed there: the download path reports the
# missing tool perfectly clearly ("need curl or wget to download fonts"), and a
# red suite on a machine that cannot download anything says nothing about the
# code under test.
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
	echo "SKIP: no curl or wget; download and checksum cases need one."
else

# A download is verified before it is cached, so a bad one is never kept and
# never mistaken for good on the next run.
setup
mkdir -p "$BASE/themes/dl"
fakefont "$BASE/src.ttf"
good=$(conf_hash_file "$BASE/src.ttf")

cat > "$BASE/themes/dl/fonts.conf" <<EOF
body.family = Downloaded
body.source = url
body.face.400.normal.url = file://$BASE/src.ttf
body.face.400.normal.sha256 = $good
EOF
fonts_merge "$BASE/md" "$BASE/themes/dl/fonts.conf"
out=$(fonts_acquire "$BASE/md" body 400 normal "$BASE/stage/fonts" 2>/dev/null); st=$?
ok "a good checksum is accepted" "0" "$st"
ok "and the face is staged" "downloaded-400-normal.ttf" "$out"
ok "and cached for next time" "yes" \
	"$([ -f "$BASE/home/fonts/downloaded/400-normal.ttf" ] && echo yes || echo no)"

setup
mkdir -p "$BASE/themes/dl"
fakefont "$BASE/src.ttf"
cat > "$BASE/themes/dl/fonts.conf" <<EOF
body.family = Tampered
body.source = url
body.face.400.normal.url = file://$BASE/src.ttf
body.face.400.normal.sha256 = 0000000000000000000000000000000000000000000000000000000000000000
EOF
fonts_merge "$BASE/mt" "$BASE/themes/dl/fonts.conf"
err=$(fonts_acquire "$BASE/mt" body 400 normal "$BASE/stage/fonts" 2>&1); st=$?
ok "a bad checksum fails" "1" "$st"
ok "and shows both hashes" "yes" \
	"$(printf '%s' "$err" | grep -q 'expected' && printf '%s' "$err" | \
	   grep -q 'actual' && echo yes || echo no)"
ok "and caches nothing" "" \
	"$(ls "$BASE/home/fonts/tampered" 2>/dev/null)"

# A corrupt download is a different thing from an unreachable one: leniency
# about fonts must not become leniency about integrity.
PDFULATOR_FONT_FALLBACK=1
err=$(fonts_acquire "$BASE/mt" body 400 normal "$BASE/stage/fonts" 2>&1); st=$?
ok "--font-fallback does NOT excuse a bad checksum" "1" "$st"
unset PDFULATOR_FONT_FALLBACK

fi  # curl/wget


section "GENERATING CSS"

setup
mkdir -p "$BASE/themes/gen"
fakefont "$BASE/themes/gen/fonts/r.otf"
fakefont "$BASE/themes/gen/fonts/i.otf"
cat > "$BASE/themes/gen/fonts.conf" <<'EOF'
body.family = TeX Gyre Pagella
body.source = local
body.face.400.normal.file = fonts/r.otf
body.face.400.italic.file = fonts/i.otf
EOF
fonts_merge "$BASE/mg" "$BASE/themes/gen/fonts.conf"
fonts_acquire "$BASE/mg" body 400 normal "$BASE/stage/fonts" >/dev/null
fonts_acquire "$BASE/mg" body 400 italic "$BASE/stage/fonts" >/dev/null
fonts_css "$BASE/mg" "$BASE/stage/fonts" "$BASE/stage/fonts.css"

ok "one @font-face per acquired face" "2" \
	"$(grep -c '@font-face' "$BASE/stage/fonts.css")"
ok "a multi-word family is quoted" "yes" \
	"$(grep -q 'font-family: "TeX Gyre Pagella"' "$BASE/stage/fonts.css" \
	   && echo yes || echo no)"
ok "the italic face is styled italic" "yes" \
	"$(grep -q 'font-style: italic' "$BASE/stage/fonts.css" && echo yes || echo no)"
ok "an .otf is opentype" "yes" \
	"$(grep -q "format('opentype')" "$BASE/stage/fonts.css" && echo yes || echo no)"
ok "src is relative to the staged directory" "yes" \
	"$(grep -q 'url(fonts/' "$BASE/stage/fonts.css" && echo yes || echo no)"
ok "the role becomes a custom property" "yes" \
	"$(grep -q -- '--pdfulator-body: "TeX Gyre Pagella", serif' \
	   "$BASE/stage/fonts.css" && echo yes || echo no)"

# A stylesheet may use var(--pdfulator-mono) whatever the theme declared, so
# every known role gets a property even when the theme never mentioned it.
ok "an undeclared role still gets a property" "yes" \
	"$(grep -q -- '--pdfulator-mono: Courier, monospace' \
	   "$BASE/stage/fonts.css" && echo yes || echo no)"
ok "and the right base-14 one" "yes" \
	"$(grep -q -- '--pdfulator-heading: Helvetica, sans-serif' \
	   "$BASE/stage/fonts.css" && echo yes || echo no)"

# The regression that matters most: under --font-fallback a role whose files
# never arrived must NOT keep naming its declared family. There is no
# @font-face for it, so the browser would substitute silently -- which is the
# exact failure this whole design exists to prevent.
setup
mkdir -p "$BASE/themes/absent"
cat > "$BASE/themes/absent/fonts.conf" <<'EOF'
body.family = Sabon
body.source = local
body.face.400.normal.file = fonts/Sabon.otf
EOF
fonts_merge "$BASE/ma" "$BASE/themes/absent/fonts.conf"
PDFULATOR_FONT_FALLBACK=1
fonts_acquire "$BASE/ma" body 400 normal "$BASE/stage/fonts" >/dev/null 2>&1
unset PDFULATOR_FONT_FALLBACK
fonts_css "$BASE/ma" "$BASE/stage/fonts" "$BASE/stage/absent.css"

ok "an unstaged role names the base-14 font, not its own" "yes" \
	"$(grep -q -- '--pdfulator-body: Times, serif' "$BASE/stage/absent.css" \
	   && echo yes || echo no)"
ok "and never names the font it could not get" "" \
	"$(grep 'Sabon' "$BASE/stage/absent.css")"
ok "and declares no @font-face for it" "0" \
	"$(grep -c '@font-face' "$BASE/stage/absent.css")"


section "GENERATING FOP"

setup
mkdir -p "$BASE/themes/fop"
fakefont "$BASE/themes/fop/fonts/r.ttf"
cat > "$BASE/themes/fop/fonts.conf" <<'EOF'
body.family = Figtree
body.source = local
body.face.700.normal.file = fonts/r.ttf
EOF
fonts_merge "$BASE/mf" "$BASE/themes/fop/fonts.conf"
fonts_acquire "$BASE/mf" body 700 normal "$BASE/stage/fonts" >/dev/null
fonts_fop_xconf "$BASE/mf" "$BASE/stage/fonts" /theme/fonts "$BASE/stage/fop.xconf"

ok "a font element is written" "1" \
	"$(grep -c '<font embed-url=' "$BASE/stage/fop.xconf")"
ok "the embed url uses the runtime base" "yes" \
	"$(grep -q 'embed-url="/theme/fonts/figtree-700-normal.ttf"' \
	   "$BASE/stage/fop.xconf" && echo yes || echo no)"

# Explicit triplets rather than a directory scan: a scan makes FOP take the
# weight from the file's own metadata, so a face declared 700 can register as
# 400 and the document silently loses its bold.
ok "the triplet carries the declared weight" "yes" \
	"$(grep -q 'weight="700"' "$BASE/stage/fop.xconf" && echo yes || echo no)"
ok "and the declared family name" "yes" \
	"$(grep -q 'name="Figtree"' "$BASE/stage/fop.xconf" && echo yes || echo no)"

# FOP cannot read WOFF at all, so a face it cannot use must be named rather
# than dropped into a PDF that then renders in something else.
setup
mkdir -p "$BASE/themes/woff"
fakefont "$BASE/themes/woff/fonts/w.woff2"
cat > "$BASE/themes/woff/fonts.conf" <<'EOF'
body.family = Webby
body.source = local
body.face.400.normal.file = fonts/w.woff2
EOF
fonts_merge "$BASE/mw" "$BASE/themes/woff/fonts.conf"
fonts_acquire "$BASE/mw" body 400 normal "$BASE/stage/fonts" >/dev/null
warn=$(fonts_fop_xconf "$BASE/mw" "$BASE/stage/fonts" /theme/fonts \
	"$BASE/stage/woff.xconf" 2>&1)

ok "a woff2 face is skipped for FOP" "0" \
	"$(grep -c '<font embed-url=' "$BASE/stage/woff.xconf")"
ok "and the skip is announced" "yes" \
	"$(printf '%s' "$warn" | grep -q 'cannot use' && echo yes || echo no)"


section "GENERATING XSL PARAMS"

setup
mkdir -p "$BASE/themes/xsl"
fakefont "$BASE/themes/xsl/fonts/r.otf"
cat > "$BASE/themes/xsl/fonts.conf" <<'EOF'
body.family = TeX Gyre Pagella
body.source = local
body.face.400.normal.file = fonts/r.otf
EOF
fonts_merge "$BASE/mx" "$BASE/themes/xsl/fonts.conf"
fonts_acquire "$BASE/mx" body 400 normal "$BASE/stage/fonts" >/dev/null
fonts_fo_params "$BASE/mx" "$BASE/stage/fonts" "$BASE/stage/fo-params"

ok "the declared family is passed" "TeX Gyre Pagella" \
	"$(grep '^body	' "$BASE/stage/fo-params" | cut -f2)"
ok "an undeclared role gets its base-14 name" "Helvetica" \
	"$(grep '^heading	' "$BASE/stage/fo-params" | cut -f2)"
ok "and mono gets Courier" "Courier" \
	"$(grep '^mono	' "$BASE/stage/fo-params" | cut -f2)"
ok "every known role is covered" "3" \
	"$(wc -l < "$BASE/stage/fo-params" | tr -d ' ')"


printf '\n'
if [ "$FAIL" = 0 ]; then
	echo "ALL EXPECTATIONS MET"
else
	echo "SOME EXPECTATIONS MISSED"
	exit 1
fi
