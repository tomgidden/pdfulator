#!/bin/sh
# Styling matrix.
#
# Which stylesheets apply, in what order, and who decided.
#
# The order is the point. The old cascade walked the theme chain on the outside
# and the three axes on the inside, so a GRANDPARENT's engines/<id>/print.css
# was concatenated after a CHILD's plain print.css -- a distant ancestor's
# engine-specific rule beating the rule the theme in front of you wrote. The
# settled order transposes that: each axis is its own inheritance chain,
# resolved end to end before the next axis begins.
#
# That is a behaviour change to shipped, tested code rather than new plumbing,
# which is why so many cases below assert on ORDER rather than on membership.
# A cascade that contains the right files in the wrong order produces a wrong
# PDF and no error at all.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/conf.sh"
. "$LIB/paths.sh"
. "$LIB/theme.sh"
. "$LIB/template.sh"
. "$LIB/styling.sh"
. "$LIB/fonts.sh"
. "$LIB/stage.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-stylingmatrix
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

# The list, with the fixture prefix stripped, as one space-separated line --
# so an assertion can state a whole expected cascade on one line and read as
# the order it is testing.
listing() {  # listing <chain> <engine> <styler> [css]
	styling_list "$1" "$2" "$3" "$BASE/engines/$2" "${4:-}" 2>/dev/null | \
		sed "s|$BASE/||" | tr '\t' ':' | tr '\n' ' ' | sed 's/ *$//'
}

# THREE levels, because the reordering is invisible with two: the rejected
# order and the settled one differ only once a grandparent exists.
setup() {
	rm -rf "$BASE"
	mkdir -p "$BASE/home" "$BASE/engines/E" "$BASE/templates/T"
	PDFULATOR_HOME="$BASE/home"
	PDFULATOR_DIR="$BASE"
	TEMPLATES_DIR="$BASE/templates"
	ENGINES_DIR="$BASE/engines"

	printf 'styler=S\n' > "$BASE/engines/E/engine.conf"

	for t in gran parent leaf; do
		mkdir -p "$BASE/themes/$t/engines/E" "$BASE/themes/$t/stylers/S"
		echo "/* $t-plain */"  > "$BASE/themes/$t/print.css"
		echo "/* $t-engine */" > "$BASE/themes/$t/engines/E/print.css"
		echo "/* $t-styler */" > "$BASE/themes/$t/stylers/S/print.css"
	done
	printf 'extends = %s\n' "$BASE/themes/gran"   > "$BASE/themes/parent/theme.conf"
	printf 'extends = %s\n' "$BASE/themes/parent" > "$BASE/themes/leaf/theme.conf"

	CHAIN=$(printf '%s\n%s\n%s\n' \
		"$BASE/themes/gran" "$BASE/themes/parent" "$BASE/themes/leaf")
}


section "THE SETTLED ORDER"

setup

# The whole cascade, stated as one line. Axis outer, chain inner.
ok "axis is the outer grouping, the theme chain the inner" \
"20:themes/gran/print.css 20:themes/parent/print.css 20:themes/leaf/print.css \
30:themes/gran/engines/E/print.css 30:themes/parent/engines/E/print.css \
30:themes/leaf/engines/E/print.css 40:themes/gran/stylers/S/print.css \
40:themes/parent/stylers/S/print.css 40:themes/leaf/stylers/S/print.css" \
	"$(listing "$CHAIN" E S)"

# The specific inversion the transpose exists to prevent, stated on its own so
# a failure names the actual defect rather than a long diff.
gran_engine=$(listing "$CHAIN" E S | tr ' ' '\n' | \
	grep -n 'gran/engines' | cut -d: -f1)
leaf_plain=$(listing "$CHAIN" E S | tr ' ' '\n' | \
	grep -n 'leaf/print.css' | cut -d: -f1)
ok "a grandparent's engine sheet does NOT beat a child's plain sheet" "yes" \
	"$([ "$gran_engine" -gt "$leaf_plain" ] && echo yes || echo no)"

# Within one axis the chain is still root-first, so a child wins by ordinary
# CSS precedence. This is the rule the old code got right and must keep.
gp=$(listing "$CHAIN" E S | tr ' ' '\n' | grep -n 'gran/print.css' | cut -d: -f1)
ok "within an axis, the parent comes before the child" "yes" \
	"$([ "$gp" -lt "$leaf_plain" ] && echo yes || echo no)"


section "LEVELS"

setup

# --css is no longer a special case appended after the fact; it is simply the
# highest level. Same behaviour, one mechanism.
echo '/* cli */' > "$BASE/cli.css"
ok "--css is the highest level" "60:cli.css" \
	"$(listing "$CHAIN" E S "$BASE/cli.css" | tr ' ' '\n' | tail -1)"

ok "--css that does not exist is an error" "1" \
	"$(styling_list "$CHAIN" E S "$BASE/engines/E" "$BASE/nope.css" \
	   >/dev/null 2>&1; echo $?)"

# The template's own styling is the floor: it knows its DOM, and a theme is
# written against it.
printf 'template.structure = ./a.tmpl\ntemplate.styling = ./t.css\n' \
	> "$BASE/templates/T/template.conf"
echo 'TMPL' > "$BASE/templates/T/a.tmpl"
echo '/* template */' > "$BASE/templates/T/t.css"
printf 'styler=S\ntemplate=T\n' > "$BASE/engines/E/engine.conf"
ok "the template's styling is the lowest level" "10:templates/T/t.css" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | head -1)"

# Level 50 is the document's YAML band. The wrapper cannot produce it -- that
# needs a real Markdown parser -- so it must be absent here rather than
# guessed at, and the engine splices its own in.
ok "the wrapper emits no document band" "" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | grep '^50:')"


section "DECLARATIONS"

setup

# A bare value REPLACES the level so far, including earlier themes: a child
# must be able to reject a parent's stylesheet, not only add to it.
echo '/* mine */' > "$BASE/themes/leaf/mine.css"
printf 'extends = %s\ntemplate.styling = ./mine.css\n' \
	"$BASE/themes/parent" > "$BASE/themes/leaf/theme.conf"
ok "an unmarked value replaces the level" "20:themes/leaf/mine.css" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | grep '^20:')"

# A `+` value ADDS. The marker is on the value, not the key, because conf_get
# splits on the first `=` -- `template.styling += x` would orphan the `+`.
printf 'extends = %s\ntemplate.styling = +./mine.css\n' \
	"$BASE/themes/parent" > "$BASE/themes/leaf/theme.conf"
ok "a + value adds to the level" \
	"20:themes/gran/print.css 20:themes/parent/print.css 20:themes/leaf/mine.css" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | grep '^20:' | tr '\n' ' ' | sed 's/ *$//')"

# Declaring anything suppresses the conventional print.css for that theme,
# or `template.styling = ./only-this.css` would not be true.
ok "a declaration suppresses the theme's own print.css" "" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | grep 'leaf/print.css')"

# So a theme wanting both names both, in the order it wants them.
printf 'extends = %s\ntemplate.styling = +./print.css\ntemplate.styling = +./mine.css\n' \
	"$BASE/themes/parent" > "$BASE/themes/leaf/theme.conf"
ok "naming both keeps both, in the order given" \
	"20:themes/leaf/print.css 20:themes/leaf/mine.css" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | grep '^20:' | tail -2 | \
	   tr '\n' ' ' | sed 's/ *$//')"

# A declaration naming a file that is not there is fatal. Silently skipping it
# is the failure this whole area exists to stop: a theme that looks applied and
# is not.
printf 'extends = %s\ntemplate.styling = ./gone.css\n' \
	"$BASE/themes/parent" > "$BASE/themes/leaf/theme.conf"
ok "a declared file that is missing is an error" "1" \
	"$(styling_list "$CHAIN" E S "$BASE/engines/E" >/dev/null 2>&1; echo $?)"

# Per-axis declarations land in their own band, not the plain one.
setup
echo '/* eng */' > "$BASE/themes/leaf/engines/E/eng.css"
printf 'template.styling = +./eng.css\n' \
	> "$BASE/themes/leaf/engines/E/theme-engine.conf"
ok "theme-engine.conf declares into the engine band" "30" \
	"$(listing "$CHAIN" E S | tr ' ' '\n' | grep 'eng.css' | cut -d: -f1)"


section "STAGING"

setup
d=$(stage_dir "$BASE/themes/leaf" E S) || d=""
ok "a staged directory is produced" "yes" "$([ -n "$d" ] && echo yes || echo no)"

# The manifest is the (level, file) tuples the engine reconciles. It names
# STAGED copies, never the originals: a container sees this directory through a
# mount and a remote engine receives it over a wire, so a path into the user's
# home would be unreadable at exactly the moment it mattered.
ok "the manifest names staged copies, not source paths" "" \
	"$(cut -f3 "$d/styling.manifest" | grep -v '^styling/')"
ok "every manifest entry exists in the staged directory" "" \
	"$(while IFS="$(printf '\t')" read -r l n f; do
	     [ -f "$d/$f" ] || printf '%s ' "$f"
	   done < "$d/styling.manifest")"
ok "the manifest has one entry per stylesheet" "9" \
	"$(wc -l < "$d/styling.manifest" | tr -d ' ')"

# Staged names are generated rather than taken from the basename, because the
# basenames COLLIDE by design -- nine files here are all called print.css.
ok "colliding basenames get distinct staged names" "9" \
	"$(cut -f3 "$d/styling.manifest" | sort -u | wc -l | tr -d ' ')"

# print.css is the concatenation for engines that just want one file, in the
# same order as the manifest.
ok "print.css concatenates every part" "9" \
	"$(grep -c '/\* --- ' "$d/print.css")"
# Compared as CONTENT, in sequence -- not as a count. Each fixture file holds
# a marker naming itself, so the markers appearing in print.css must be the
# markers of the manifest's files, in the manifest's order. Comparing lengths
# would pass with the concatenation reversed, which is a wrong PDF and no error.
ok "print.css is in manifest order" "yes" \
	"$(a=$(sed -n 's|^/\* \(.*\) \*/$|\1|p' "$d/print.css" | grep -v '^---')
	   b=$(while IFS="$(printf '\t')" read -r l n f; do
	         sed -n 's|^/\* \(.*\) \*/$|\1|p' "$d/$f"
	       done < "$d/styling.manifest")
	   [ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo no)"

# The provenance comment must name the file to go and EDIT, which is the
# original -- the staged copy's name says where it sits, not where it came from.
ok "provenance comments name the original path" "yes" \
	"$(grep -q "/\* --- $BASE/themes/gran/print.css --- \*/" "$d/print.css" \
	   && echo yes || echo no)"

# Identity: a stylesheet the cascade selected is part of the key even when it
# is not called print.css and not in a theme directory at all.
setup
printf 'template.structure = ./a.tmpl\ntemplate.styling = ./t.css\n' \
	> "$BASE/templates/T/template.conf"
echo 'TMPL' > "$BASE/templates/T/a.tmpl"
echo '/* v1 */' > "$BASE/templates/T/t.css"
printf 'styler=S\ntemplate=T\n' > "$BASE/engines/E/engine.conf"
one=$(stage_dir "$BASE/themes/leaf" E S)
echo '/* v2 */' > "$BASE/templates/T/t.css"
two=$(stage_dir "$BASE/themes/leaf" E S)
ok "editing a template's stylesheet restages" "no" \
	"$([ "$one" = "$two" ] && echo yes || echo no)"

# --css is part of the identity too: two runs differing only in their extra
# sheet must not share a directory.
echo '/* cli */' > "$BASE/cli.css"
three=$(stage_dir "$BASE/themes/leaf" E S fonts "$BASE/cli.css")
ok "--css changes the staged identity" "no" \
	"$([ "$two" = "$three" ] && echo yes || echo no)"


section "COMPATIBILITY"

# A theme that declares nothing works exactly as it did: print.css by name.
# Every shipped theme is this shape, so it is the case that must not move.
setup
rm -f "$BASE/themes/leaf/theme.conf"
printf 'extends = %s\n' "$BASE/themes/parent" > "$BASE/themes/leaf/theme.conf"
ok "an undeclared theme still contributes print.css by name" "yes" \
	"$(listing "$CHAIN" E S | grep -q '20:themes/leaf/print.css' \
	   && echo yes || echo no)"

# A theme with no stylesheet at all is not an error.
setup
rm -f "$BASE/themes/leaf/print.css" "$BASE/themes/leaf/engines/E/print.css" \
      "$BASE/themes/leaf/stylers/S/print.css"
ok "a theme with no stylesheets is not an error" "0" \
	"$(styling_list "$CHAIN" E S "$BASE/engines/E" >/dev/null 2>&1; echo $?)"

exit $FAIL
