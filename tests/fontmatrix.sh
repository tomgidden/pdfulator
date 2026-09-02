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
cat > "$BASE/themes/one/theme.conf" <<'EOF'
# a comment, and a blank line follow

font.body.name   = EB Garamond
font.body.source   = local
font.body.face.400.normal.file = fonts/eb-regular.otf
font.body.face.700.normal.file = fonts/eb-bold.otf
font.body.face.400.italic.file = fonts/eb-italic.otf
font.mono.name = Noto Sans Mono
font.mono.source = none
style.body.font = body
style.mono.font = mono
EOF

ok "a value is read" "EB Garamond" \
	"$(conf_get "$BASE/themes/one/theme.conf" font.body.name)"
ok "whitespace around = is ignored" "local" \
	"$(conf_get "$BASE/themes/one/theme.conf" font.body.source)"
ok "roles are found" "body mono" \
	"$(fonts_ids "$BASE/themes/one/theme.conf" | tr '\n' ' ' | sed 's/ $//')"
ok "faces are found, deduplicated" "400 normal|700 normal|400 italic" \
	"$(fonts_faces "$BASE/themes/one/theme.conf" body | tr '\n' '|' | sed 's/|$//')"
ok "a role with no faces has none" "" \
	"$(fonts_faces "$BASE/themes/one/theme.conf" mono)"


section "MERGING"

# The case the whole cascade exists for: a child that changes only its body
# font must inherit the rest untouched, so that a theme can be one short file.
setup
mkdir -p "$BASE/themes/parent" "$BASE/themes/child"
cat > "$BASE/themes/parent/theme.conf" <<'EOF'
font.body.name = Parent Serif
font.body.source = none
font.heading.name = Parent Sans
font.heading.source = none
font.mono.name = Parent Mono
font.mono.source = none
style.body.font = body
style.heading.font = heading
style.mono.font = mono
EOF
cat > "$BASE/themes/child/theme.conf" <<'EOF'
font.body.name = Child Serif
font.body.source = none
style.body.font = body
EOF

fonts_merge "$BASE/merged" \
	"$BASE/themes/parent/theme.conf" "$BASE/themes/child/theme.conf"

ok "the child's role wins" "Child Serif" \
	"$(fonts_merged_get "$BASE/merged" body.name)"
ok "an unmentioned role is inherited" "Parent Sans" \
	"$(fonts_merged_get "$BASE/merged" heading.name)"
ok "and so is another" "Parent Mono" \
	"$(fonts_merged_get "$BASE/merged" mono.name)"
ok "every role is present once" "body heading mono" \
	"$(fonts_merged_roles "$BASE/merged" | sort | tr '\n' ' ' | sed 's/ $//')"

# The merged file must contain the winning role *once*, not both copies with
# the loser after it. Readers take the first match, so a merge that simply
# concatenated would still answer every question above correctly while leaving
# the parent's keys in the file -- and the next reader to iterate rather than
# look up would see the role twice.
ok "the losing copy is not left in the file" "1" \
	"$(grep -c 'body\.name' "$BASE/merged")"
ok "nor its value" "" \
	"$(grep 'Parent Serif' "$BASE/merged")"

# A role is replaced wholesale, not merged key by key: a child naming a new
# family without naming faces must not inherit the parent's *files*, which
# would pair a new name with the old glyphs.
cat > "$BASE/themes/parent/theme.conf" <<'EOF'
font.body.name = Parent Serif
font.body.source = local
font.body.face.400.normal.file = fonts/parent.otf
style.body.font = body
EOF
cat > "$BASE/themes/child/theme.conf" <<'EOF'
font.body.name = Child Serif
font.body.source = none
style.body.font = body
EOF
fonts_merge "$BASE/merged2" \
	"$BASE/themes/parent/theme.conf" "$BASE/themes/child/theme.conf"
ok "a replaced role keeps none of the parent's faces" "" \
	"$(fonts_merged_faces "$BASE/merged2" body)"

# A local path must stay relative to the file that declared it, even after the
# merge has combined files from different directories.
setup
mkdir -p "$BASE/themes/a" "$BASE/themes/b"
cat > "$BASE/themes/a/theme.conf" <<'EOF'
font.mono.name = A Mono
font.mono.source = local
font.mono.face.400.normal.file = fonts/a.otf
style.mono.font = mono
EOF
cat > "$BASE/themes/b/theme.conf" <<'EOF'
font.body.name = B Serif
font.body.source = local
font.body.face.400.normal.file = fonts/b.otf
style.body.font = body
EOF
fonts_merge "$BASE/merged3" \
	"$BASE/themes/a/theme.conf" "$BASE/themes/b/theme.conf"
ok "each role remembers its own directory" "$BASE/themes/a" \
	"$(fonts_merged_dir "$BASE/merged3" mono.face.400.normal.file)"
ok "and the other one too" "$BASE/themes/b" \
	"$(fonts_merged_dir "$BASE/merged3" body.face.400.normal.file)"


section "ACQUIRING"

setup
mkdir -p "$BASE/themes/local"
fakefont "$BASE/themes/local/fonts/real.otf"
cat > "$BASE/themes/local/theme.conf" <<'EOF'
font.body.name = Real Font
font.body.source = local
font.body.face.400.normal.file = fonts/real.otf
style.body.font = body
EOF
fonts_merge "$BASE/m" "$BASE/themes/local/theme.conf"

out=$(fonts_acquire "$BASE/m" body 400 normal "$BASE/stage/fonts")
ok "a local face is staged" "real-font-400-normal.otf" "$out"
ok "and the file is really there" "yes" \
	"$([ -f "$BASE/stage/fonts/real-font-400-normal.otf" ] && echo yes || echo no)"

# The Sabon case: named, absent, and until now silently rendered as Times.
cat > "$BASE/themes/local/theme.conf" <<'EOF'
font.body.name = Sabon
font.body.source = local
font.body.face.400.normal.file = fonts/Sabon.otf
style.body.font = body
EOF
fonts_merge "$BASE/m2" "$BASE/themes/local/theme.conf"

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

cat > "$BASE/themes/local/theme.conf" <<'EOF'
font.body.name = Whatever
font.body.source = google
style.body.font = body
EOF
fonts_merge "$BASE/m3" "$BASE/themes/local/theme.conf"
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

cat > "$BASE/themes/dl/theme.conf" <<EOF
font.body.name = Downloaded
font.body.source = url
font.body.face.400.normal.url = file://$BASE/src.ttf
font.body.face.400.normal.sha256 = $good
style.body.font = body
EOF
fonts_merge "$BASE/md" "$BASE/themes/dl/theme.conf"
out=$(fonts_acquire "$BASE/md" body 400 normal "$BASE/stage/fonts" 2>/dev/null); st=$?
ok "a good checksum is accepted" "0" "$st"
ok "and the face is staged" "downloaded-400-normal.ttf" "$out"
ok "and cached for next time" "yes" \
	"$([ -f "$BASE/home/fonts/downloaded/400-normal.ttf" ] && echo yes || echo no)"

setup
mkdir -p "$BASE/themes/dl"
fakefont "$BASE/src.ttf"
cat > "$BASE/themes/dl/theme.conf" <<EOF
font.body.name = Tampered
font.body.source = url
font.body.face.400.normal.url = file://$BASE/src.ttf
font.body.face.400.normal.sha256 = 0000000000000000000000000000000000000000000000000000000000000000
style.body.font = body
EOF
fonts_merge "$BASE/mt" "$BASE/themes/dl/theme.conf"
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
cat > "$BASE/themes/gen/theme.conf" <<'EOF'
font.body.name = TeX Gyre Pagella
font.body.source = local
font.body.face.400.normal.file = fonts/r.otf
font.body.face.400.italic.file = fonts/i.otf
style.body.font = body
EOF
fonts_merge "$BASE/mg" "$BASE/themes/gen/theme.conf"
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
	"$(grep -q -- '--pdfulator-body: "TeX Gyre Pagella";' \
	   "$BASE/stage/fonts.css" && echo yes || echo no)"

# NO GENERIC TAIL on a font that resolved. `"Sabon", serif` reads like prudence
# and is the opposite: the wrapper placed the file, so the tail is unreachable
# when acquisition succeeded and a silent substitution when it did not -- which
# is the Sabon failure the rest of this file exists to prevent. The tail stays
# only where the name might not resolve: the base-14 substitution below.
ok "and carries no generic fallback" "no" \
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
cat > "$BASE/themes/absent/theme.conf" <<'EOF'
font.body.name = Sabon
font.body.source = local
font.body.face.400.normal.file = fonts/Sabon.otf
style.body.font = body
EOF
fonts_merge "$BASE/ma" "$BASE/themes/absent/theme.conf"
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
cat > "$BASE/themes/fop/theme.conf" <<'EOF'
font.body.name = Figtree
font.body.source = local
font.body.face.700.normal.file = fonts/r.ttf
style.body.font = body
EOF
fonts_merge "$BASE/mf" "$BASE/themes/fop/theme.conf"
fonts_acquire "$BASE/mf" body 700 normal "$BASE/stage/fonts" >/dev/null
fonts_fop_xconf "$BASE/mf" "$BASE/stage/fonts" /payload/fonts "$BASE/stage/fop.xconf"

ok "a font element is written" "1" \
	"$(grep -c '<font embed-url=' "$BASE/stage/fop.xconf")"
ok "the embed url uses the runtime base" "yes" \
	"$(grep -q 'embed-url="/payload/fonts/figtree-700-normal.ttf"' \
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
cat > "$BASE/themes/woff/theme.conf" <<'EOF'
font.body.name = Webby
font.body.source = local
font.body.face.400.normal.file = fonts/w.woff2
style.body.font = body
EOF
fonts_merge "$BASE/mw" "$BASE/themes/woff/theme.conf"
fonts_acquire "$BASE/mw" body 400 normal "$BASE/stage/fonts" >/dev/null
warn=$(fonts_fop_xconf "$BASE/mw" "$BASE/stage/fonts" /payload/fonts \
	"$BASE/stage/woff.xconf" 2>&1)

ok "a woff2 face is skipped for FOP" "0" \
	"$(grep -c '<font embed-url=' "$BASE/stage/woff.xconf")"
ok "and the skip is announced" "yes" \
	"$(printf '%s' "$warn" | grep -q 'cannot use' && echo yes || echo no)"


section "GENERATING XSL PARAMS"

setup
mkdir -p "$BASE/themes/xsl"
fakefont "$BASE/themes/xsl/fonts/r.otf"
cat > "$BASE/themes/xsl/theme.conf" <<'EOF'
font.body.name = TeX Gyre Pagella
font.body.source = local
font.body.face.400.normal.file = fonts/r.otf
style.body.font = body
EOF
fonts_merge "$BASE/mx" "$BASE/themes/xsl/theme.conf"
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


section "DEFINITIONS AND BINDINGS"

# THE POINT OF THE font.<id> / style.<x>.font SPLIT.
#
# A child theme changing its body font must get that font and ONLY that font.
# The earlier design put the family name and the face files under one `<role>.`
# prefix, so per-key merging could pair one family's NAME with another's GLYPH
# FILES: roman in Baskerville, every italic and bold in Pagella, under an
# @font-face asserting all of it was Baskerville. Nothing reported it -- the
# faces have different weight/style descriptors, so the CSS rule that a later
# @font-face replaces an identical earlier one never fires.
#
# With the split it is not representable: face keys live under font.<id>, the
# binding lives under style.<x>.font, and they are different keys.
setup
mkdir -p "$BASE/themes/p2" "$BASE/themes/c2"
cat > "$BASE/themes/p2/theme.conf" <<'EOF'
font.pagella.name = TeX Gyre Pagella
font.pagella.source = none
font.pagella.face.400.normal.file = fonts/pagella-regular.otf
font.pagella.face.400.italic.file = fonts/pagella-italic.otf
font.pagella.face.700.normal.file = fonts/pagella-bold.otf
font.opensans.name = Open Sans
font.opensans.source = none
style.body.font = pagella
style.heading.font = opensans
EOF
cat > "$BASE/themes/c2/theme.conf" <<'EOF'
font.baskerville.name = Baskerville
font.baskerville.source = none
font.baskerville.face.400.normal.file = fonts/baskerville-regular.otf
style.body.font = baskerville
EOF
fonts_merge "$BASE/split" \
	"$BASE/themes/p2/theme.conf" "$BASE/themes/c2/theme.conf"

ok "the binding picks the child's font" "Baskerville" \
	"$(fonts_merged_get "$BASE/split" body.name)"

# The heart of it: NONE of the parent's faces survive under the child's name.
ok "and none of the parent's faces come with it" "400 normal" \
	"$(fonts_merged_faces "$BASE/split" body | tr '\n' '|' | sed 's/|$//')"
ok "no parent face file is re-labelled" "0" \
	"$(grep -c 'pagella' "$BASE/split")"

# A role the child never mentioned keeps the parent's binding untouched, which
# is what makes a one-line theme possible.
ok "an unbound role is inherited whole" "Open Sans" \
	"$(fonts_merged_get "$BASE/split" heading.name)"

# A definition nothing binds is never merged in -- which is what makes
# acquisition demand-driven: an unreferenced font is never downloaded.
ok "an unreferenced definition is not staged" "0" \
	"$(grep -c 'Open Sans' "$BASE/themes/c2/theme.conf")"
setup
mkdir -p "$BASE/themes/un"
cat > "$BASE/themes/un/theme.conf" <<'EOF'
font.used.name = Used
font.used.source = none
font.spare.name = Spare
font.spare.source = none
style.body.font = used
EOF
fonts_merge "$BASE/unref" "$BASE/themes/un/theme.conf"
ok "an unbound font never reaches the merge" "0" \
	"$(grep -c 'Spare' "$BASE/unref")"

# Roles stay OPEN: a theme may invent one, and it reaches CSS. It does NOT
# reach fo-params, because FOP has a fixed idea of what a document's fonts are
# for and an invented role has no generic meaning to a typesetter.
#
# The bug this pins: fonts_base14 and fonts_css_generic both fell through a
# `*)` arm, so an invented role got `Times, serif` whatever it declared.
setup
mkdir -p "$BASE/themes/inv" "$BASE/stage/fonts"
cat > "$BASE/themes/inv/theme.conf" <<'EOF'
font.georgia.name = Georgia
font.georgia.source = none
style.pullquote.font = georgia
EOF
fonts_merge "$BASE/mi" "$BASE/themes/inv/theme.conf"
fonts_css "$BASE/mi" "$BASE/stage/fonts" "$BASE/stage/inv.css"
ok "an invented role gets what it declared" "yes" \
	"$(grep -q -- '--pdfulator-pullquote: Georgia;' "$BASE/stage/inv.css" \
	   && echo yes || echo no)"
ok "and not body's base-14 font" "no" \
	"$(grep -q -- '--pdfulator-pullquote: Times' "$BASE/stage/inv.css" \
	   && echo yes || echo no)"

fonts_fo_params "$BASE/mi" "$BASE/stage/fonts" "$BASE/stage/inv-params"
ok "an invented role is not given to FOP" "0" \
	"$(grep -c 'pullquote' "$BASE/stage/inv-params")"

# And the FAILURE path, which is where fonts_base14 is actually consulted: a
# `local` font whose file never arrived. A known role substitutes its base-14
# name; an invented one has no base-14 equivalent -- there is no "the standard
# pullquote font" -- so it must emit NOTHING rather than silently naming Times,
# which is what the `*)` arm used to do.
setup
mkdir -p "$BASE/themes/inv2" "$BASE/stage/fonts"
cat > "$BASE/themes/inv2/theme.conf" <<'EOF'
font.missing.name = Missing Face
font.missing.source = local
font.missing.face.400.normal.file = fonts/nope.otf
style.pullquote.font = missing
EOF
fonts_merge "$BASE/mi2" "$BASE/themes/inv2/theme.conf"
fonts_css "$BASE/mi2" "$BASE/stage/fonts" "$BASE/stage/inv2.css"
ok "an unresolvable invented role emits no property" "0" \
	"$(grep -c -- '--pdfulator-pullquote' "$BASE/stage/inv2.css")"


printf '\n'
if [ "$FAIL" = 0 ]; then
	echo "ALL EXPECTATIONS MET"
else
	echo "SOME EXPECTATIONS MISSED"
	exit 1
fi
