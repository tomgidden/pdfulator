#!/bin/sh
# Staging matrix.
#
# The wrapper hands an engine a directory it built, not the theme the user
# named. These cases pin what ends up in it: which file won, what order the CSS
# was concatenated in, and whether the same inputs give the same answer twice.
#
# The caching is the part worth testing hardest. A directory job or a watch
# session stages once and converts many times, so a key that changes when it
# should not means re-downloading fonts per document, and a key that fails to
# change when it should means editing a theme has no effect -- which is far
# worse, because it looks like the edit was wrong.
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO/lib"
. "$LIB/conf.sh"
. "$LIB/paths.sh"
. "$LIB/theme.sh"
. "$LIB/template.sh"
. "$LIB/styling.sh"
. "$LIB/fonts.sh"
. "$LIB/stage.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-stagematrix
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

fakefont() {
	mkdir -p -- "$(dirname -- "$1")"
	printf 'not really a font\n' > "$1"
}

# A two-level theme with per-styler and per-engine overrides, which is every
# lookup rule in one fixture.
setup() {
	rm -rf "$BASE"
	mkdir -p "$BASE/home" \
	         "$BASE/themes/base" \
	         "$BASE/themes/derived/stylers/vivliostyle" \
	         "$BASE/themes/derived/engines/pandoc-xslt"

	PDFULATOR_HOME="$BASE/home"
	PDFULATOR_DIR="$BASE"
	# PDFULATOR_DIR is the fixture, so stage_lib would find no lib/payload/
	# there and the payload would ship no reader. The reader under test is the
	# repository's, and it is what a real payload carries.
	PDFULATOR_LIB="$REPO/lib"
	BUILTIN_THEME="$BASE/theme"
	unset PDFULATOR_FONT_FALLBACK

	echo 'BASE-CSS'    > "$BASE/themes/base/print.css"
	echo 'DERIVED-CSS' > "$BASE/themes/derived/print.css"
	echo 'VIVLIO-CSS'  > "$BASE/themes/derived/stylers/vivliostyle/print.css"

	# Two template objects in two ecosystems, and an engine naming one. This is
	# what replaced staging a file called article.tmpl out of the theme chain:
	# the two files below have the same name and incompatible syntax, which is
	# precisely the confusion the object type exists to prevent.
	mkdir -p "$BASE/templates/mustache" "$BASE/templates/pandoc"
	echo 'MUSTACHE-TMPL' > "$BASE/templates/mustache/article.tmpl"
	echo 'PANDOC-TMPL'   > "$BASE/templates/pandoc/article.tmpl"
	printf 'template.structure = ./article.tmpl\n' \
		> "$BASE/templates/mustache/template.conf"
	printf 'template.structure = ./article.tmpl\n' \
		> "$BASE/templates/pandoc/template.conf"
	TEMPLATES_DIR="$BASE/templates"

	mkdir -p "$BASE/engines/vivlio" "$BASE/engines/pandoc-pagedjs"
	printf 'styler=vivliostyle\ntemplate=mustache\n' \
		> "$BASE/engines/vivlio/engine.conf"
	printf 'styler=pagedjs\ntemplate=pandoc\n' \
		> "$BASE/engines/pandoc-pagedjs/engine.conf"
	ENGINES_DIR="$BASE/engines"

	printf 'extends = base\n' > "$BASE/themes/derived/theme.conf"

	fakefont "$BASE/themes/base/fonts/b.otf"
	cat > "$BASE/themes/base/fonts.conf" <<'EOF'
body.family = Base Serif
body.source = local
body.face.400.normal.file = fonts/b.otf
mono.family = Base Mono
mono.source = none
EOF
}


section "CASCADED FILES"

setup
d=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle) || d=""
ok "a staged directory is produced" "yes" "$([ -n "$d" ] && echo yes || echo no)"

# Root first, child last: CSS decides by order, so the child's rules must come
# after the parent's to win.
ok "the parent's CSS comes first" "1" \
	"$(grep -n 'BASE-CSS' "$d/print.css" | cut -d: -f1 | head -1 | \
	   awk '{print ($1 < 4) ? 1 : 0}')"
ok "all three levels are present" "3" \
	"$(grep -c 'CSS$' "$d/print.css")"
ok "the styler's CSS comes last" "yes" \
	"$(tail -3 "$d/print.css" | grep -q 'VIVLIO-CSS' && echo yes || echo no)"
ok "each part says where it came from" "3" \
	"$(grep -c '/\* --- ' "$d/print.css")"

# The template comes from the engine's declared ecosystem, not from a file
# named article.tmpl in the theme chain. This is the regression that mattered:
# both templates below are called article.tmpl and only one is Mustache.
#
# Read from the MIRROR, not from the payload root. There is no copy at the root
# any more: every engine asks the payload what its structural file is called
# (main.js via payload.js, both pandoc renders via _lib/payload.sh), so a copy
# under an agreed name would only invite something to depend on the name again.
# The property under test is unchanged -- which template arrives -- so the
# assertion moves rather than goes.
staged_markup() {  # staged_markup <payload>
	sh "$1/_lib/payload.sh" markup "$1" 2>/dev/null
}

ok "the engine's template ecosystem is staged" "MUSTACHE-TMPL" \
	"$(cat "$d/$(staged_markup "$d")" 2>/dev/null)"

dp=$(stage_dir "$BASE/themes/derived" pandoc-pagedjs pagedjs) || dp=""
ok "a different engine gets a different template" "PANDOC-TMPL" \
	"$(cat "$dp/$(staged_markup "$dp")" 2>/dev/null)"
ok "and they are not the same staged directory" "no" \
	"$([ "$d" = "$dp" ] && echo yes || echo no)"

# The bug itself, stated as a property: a theme dropping an article.tmpl into
# its own directory must not reach an engine of another ecosystem. Before the
# template object this file was staged by name and pandoc received Mustache.
echo 'THEME-MUSTACHE' > "$BASE/themes/derived/article.tmpl"
dp2=$(stage_dir "$BASE/themes/derived" pandoc-pagedjs pagedjs) || dp2=""
ok "a theme's stray article.tmpl does not reach another ecosystem" "PANDOC-TMPL" \
	"$(cat "$dp2/$(staged_markup "$dp2")" 2>/dev/null)"
rm -f "$BASE/themes/derived/article.tmpl"

# A template's support files land beside its structure. The DocBook template
# needs global.ent there, because the SYSTEM entity that pulls it in resolves
# relative to the template -- staged without it, pandoc fails on the DTD subset
# before the conversion starts.
echo 'ENTITIES' > "$BASE/templates/pandoc/extra.ent"
printf 'template.structure = ./article.tmpl\ntemplate.support = ./extra.ent\n' \
	> "$BASE/templates/pandoc/template.conf"
ds=$(stage_dir "$BASE/themes/derived" pandoc-pagedjs pagedjs) || ds=""
# Beside the structure in the mirror, which is the position that matters: a
# SYSTEM entity resolves relative to the file naming it, so the support file has
# to sit next to the template wherever the template actually is.
ok "a support file is staged beside the structure" "ENTITIES" \
	"$(cat "$(dirname -- "$ds/$(staged_markup "$ds")")/extra.ent" 2>/dev/null)"

# The legacy root copy is gone, and must stay gone: an engine that found
# `article.tmpl` there would work by name again, which is the coupling the
# template object exists to remove.
ok "no template is staged at the payload root" "no" \
	"$([ -e "$ds/article.tmpl" ] && echo yes || echo no)"

# And it is part of the identity: editing one must restage, or the cache serves
# a directory built before the change.
echo 'CHANGED' > "$BASE/templates/pandoc/extra.ent"
ds2=$(stage_dir "$BASE/themes/derived" pandoc-pagedjs pagedjs) || ds2=""
ok "editing a support file restages" "no" \
	"$([ "$ds" = "$ds2" ] && echo yes || echo no)"


section "STYLER AND ENGINE SELECTION"

# The reason stylers/ exists: vivlio and vivlio-docker are the same renderer,
# so a theme writes their CSS once and both pick it up.
setup
a=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
b=$(stage_dir "$BASE/themes/derived" vivlio-docker vivliostyle)
ok "docker and non-docker see the same styler CSS" "yes" \
	"$(grep -q 'VIVLIO-CSS' "$b/print.css" && echo yes || echo no)"

# A different styler must not pick up vivliostyle's sheet.
c=$(stage_dir "$BASE/themes/derived" pandoc-pagedjs pagedjs)
ok "another styler does not" "" \
	"$(grep 'VIVLIO-CSS' "$c/print.css")"

# An engine directory beats a styler directory.
setup
echo 'XSLT-ONLY' > "$BASE/themes/derived/engines/pandoc-xslt/print.css"
e=$(stage_dir "$BASE/themes/derived" pandoc-xslt xsl-fo)
ok "an engine override is used" "yes" \
	"$(grep -q 'XSLT-ONLY' "$e/print.css" && echo yes || echo no)"


section "GENERATED FILES"

setup
d=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
ok "fonts.css is generated" "yes" \
	"$([ -f "$d/fonts.css" ] && echo yes || echo no)"
ok "fo-params is generated" "yes" \
	"$([ -f "$d/fo-params" ] && echo yes || echo no)"
ok "the font file is staged" "yes" \
	"$([ -f "$d/fonts/base-serif-400-normal.otf" ] && echo yes || echo no)"

# FOP config only where it means anything: a vivlio theme carrying a stray
# fop-fonts.xconf is misleading rather than harmless.
ok "no FOP config for a CSS styler" "" \
	"$(ls "$d/fop-fonts.xconf" 2>/dev/null)"
x=$(stage_dir "$BASE/themes/derived" pandoc-xslt xsl-fo)
ok "but there is one for xsl-fo" "yes" \
	"$([ -f "$x/fop-fonts.xconf" ] && echo yes || echo no)"

# The inherited role survives into the generated output, which is the cascade
# and the generators working together rather than either alone.
ok "an inherited font reaches the CSS" "yes" \
	"$(grep -q 'Base Serif' "$d/fonts.css" && echo yes || echo no)"


section "CACHING"

setup
one=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
two=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
ok "the same inputs give the same directory" "yes" \
	"$([ "$one" = "$two" ] && echo yes || echo no)"
ok "and it is only built once" "1" \
	"$(ls "$BASE/home/cache" | wc -l | tr -d ' ')"

# Different engines can need different content, so they must not share a key.
three=$(stage_dir "$BASE/themes/derived" pandoc-xslt xsl-fo)
ok "a different styler gets its own" "no" \
	"$([ "$one" = "$three" ] && echo yes || echo no)"

# The one that matters: editing a theme must invalidate the cache, or the edit
# appears to do nothing at all.
echo 'CHANGED' >> "$BASE/themes/derived/print.css"
four=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
ok "editing the theme rebuilds" "no" \
	"$([ "$one" = "$four" ] && echo yes || echo no)"
ok "and the change is in the output" "yes" \
	"$(grep -q 'CHANGED' "$four/print.css" && echo yes || echo no)"

# Editing the *parent* must invalidate too: inheritance means a parent's
# content is part of the child's result.
echo 'PARENT-CHANGED' >> "$BASE/themes/base/print.css"
five=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
ok "editing the parent rebuilds too" "no" \
	"$([ "$four" = "$five" ] && echo yes || echo no)"

# Content, not mtime: a theme touched but unchanged should not restage, or a
# fresh checkout would rebuild everything for no reason.
touch "$BASE/themes/derived/print.css"
six=$(stage_dir "$BASE/themes/derived" vivlio vivliostyle)
ok "touching without changing does not" "yes" \
	"$([ "$five" = "$six" ] && echo yes || echo no)"


section "FAILURE"

# A build that cannot finish must leave nothing behind that the next run would
# mistake for a finished one.
setup
mkdir -p "$BASE/themes/broken"
printf 'extends = base\n' > "$BASE/themes/broken/theme.conf"
cat > "$BASE/themes/broken/fonts.conf" <<'EOF'
body.family = Sabon
body.source = local
body.face.400.normal.file = fonts/Sabon.otf
EOF

before=$(ls "$BASE/home/cache" 2>/dev/null | wc -l | tr -d ' ')
out=$(stage_dir "$BASE/themes/broken" vivlio vivliostyle 2>/dev/null); st=$?
after=$(ls "$BASE/home/cache" 2>/dev/null | wc -l | tr -d ' ')

ok "a missing font fails the build" "1" "$st"
ok "and prints no directory" "" "$out"
ok "and leaves no cached directory" "$before" "$after"
ok "and no half-built one either" "" \
	"$(ls -d "$BASE/home/cache"/*.building.* 2>/dev/null)"

PDFULATOR_FONT_FALLBACK=1
out=$(stage_dir "$BASE/themes/broken" vivlio vivliostyle 2>/dev/null); st=$?
ok "--font-fallback lets it build" "0" "$st"
unset PDFULATOR_FONT_FALLBACK

# A loop must be reported rather than run into.
setup
mkdir -p "$BASE/themes/loop"
printf 'extends = loop\n' > "$BASE/themes/loop/theme.conf"
out=$(stage_dir "$BASE/themes/loop" vivlio vivliostyle 2>/dev/null); st=$?
ok "an inheritance loop fails" "1" "$st"


printf '\n'
if [ "$FAIL" = 0 ]; then
	echo "ALL EXPECTATIONS MET"
else
	echo "SOME EXPECTATIONS MISSED"
	exit 1
fi
