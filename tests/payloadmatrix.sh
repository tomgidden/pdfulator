#!/bin/sh
# Payload matrix.
#
# The payload is what an engine actually receives: every object that took part
# in the build, copied whole to its position in the source tree. These cases
# pin the two properties that makes it worth building that way.
#
# SELF-DESCRIBING. Every selected object's conf file is present -- engine.conf,
# template.conf, a theme.conf for each theme in the chain, and the conf for
# each axis that was chosen. That is what lets an engine walk the payload and
# read what each object declared, instead of being handed a manifest that
# staging had to remember to write, or hunting for a file by an agreed name.
# A theme that contributes no stylesheet still has to be there: it carries the
# `extends` the walk follows, and leaving it out puts a hole in the chain.
#
# AND NO MORE THAN THAT. The payload gets mounted into containers and will be
# sent to remote hosts, so what does not travel matters as much as what does.
# `_nopayload/` is the convention and `do.not.payload` is how an object amends
# it -- with the same `+`-adds/bare-replaces rule every other list key uses.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/conf.sh"
. "$LIB/paths.sh"
. "$LIB/theme.sh"
. "$LIB/template.sh"
. "$LIB/styling.sh"
. "$LIB/fonts.sh"
. "$LIB/stage.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-payloadmatrix
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

# Present as a file in the payload?
has() {  # has <payload> <relative path>
	[ -f "$1/$2" ] && echo yes || echo no
}

rm -rf "$BASE"
mkdir -p "$BASE"


# --- do.not.payload, on its own ---------------------------------------------
#
# Read straight out of stage_nopayload_list, because the folding rule is where
# the semantics live and a payload-level test would only show the result.

section "do.not.payload"

O="$BASE/obj"
mkdir -p "$O"

ok "the default is _nopayload" \
   "_nopayload" "$(stage_nopayload_list "$O")"

printf 'do.not.payload = +convert\n' > "$O/engine.conf"
ok "+ adds to the default" \
   "_nopayload convert" "$(stage_nopayload_list "$O")"

printf 'do.not.payload = +convert\ndo.not.payload = +build\n' > "$O/engine.conf"
ok "every occurrence counts" \
   "_nopayload convert build" "$(stage_nopayload_list "$O")"

# A bare value replaces, the same reading `stylesheet = x.css` has. This is the
# escape hatch for an object whose layout the convention does not suit: it can
# say `do.not.payload = build` and have _nopayload/ travel like anything else.
printf 'do.not.payload = build\n' > "$O/engine.conf"
ok "a bare value replaces the default" \
   "build" "$(stage_nopayload_list "$O")"

# Only the FIRST bare value replaces. A second one accumulating rather than
# replacing again is what stops `do.not.payload = a` / `do.not.payload = b`
# from silently meaning just `b`.
printf 'do.not.payload = a\ndo.not.payload = b\n' > "$O/engine.conf"
ok "a second bare value adds rather than replacing again" \
   "a b" "$(stage_nopayload_list "$O")"

# The key is read from whichever conf file the object has, so the rule is the
# same for a theme as for an engine.
rm -f "$O/engine.conf"
printf 'do.not.payload = +secrets\n' > "$O/theme.conf"
ok "the key is read from theme.conf too" \
   "_nopayload secrets" "$(stage_nopayload_list "$O")"
rm -f "$O/theme.conf"


# --- A whole payload --------------------------------------------------------
#
# Three themes, because the chain is what the walk has to survive: base
# contributes a stylesheet, mid contributes NOTHING but its extends, and leaf
# contributes a styler sheet only. If the mirror only copied directories that
# supplied a stylesheet -- which is what it did before -- mid would be missing
# and the chain would have a hole in the middle.

section "a payload is self-describing"

R="$BASE/root"
mkdir -p "$R/engines/eng/_nopayload" "$R/templates/tmpl" \
         "$R/themes/base" "$R/themes/mid" \
         "$R/themes/leaf/stylers/sty" "$R/themes/leaf/stylers/other" \
         "$R/themes/leaf/engines/eng"

cat > "$R/engines/eng/engine.conf" <<'EOF'
id=eng
template=tmpl
stylesheet = +./engine.css
do.not.payload = +convert
EOF
printf '/* engine */\n' > "$R/engines/eng/engine.css"
printf '#!/bin/sh\n'    > "$R/engines/eng/convert"
printf 'runtime\n'      > "$R/engines/eng/_nopayload/main.js"

printf 'template.structure = ./markup.html\n' > "$R/templates/tmpl/template.conf"
printf '<html></html>\n'                      > "$R/templates/tmpl/markup.html"

printf 'name = base\ntemplate.styling = ./base.css\n' > "$R/themes/base/theme.conf"
printf '/* base */\n'                                 > "$R/themes/base/base.css"

# Contributes no stylesheet at all -- only its place in the chain.
printf 'name = mid\nextends = base\n' > "$R/themes/mid/theme.conf"

printf 'name = leaf\nextends = mid\n' > "$R/themes/leaf/theme.conf"
printf 'template.styling = +./leaf-sty.css\n' \
	> "$R/themes/leaf/stylers/sty/theme-styler.conf"
printf '/* leaf styler */\n' > "$R/themes/leaf/stylers/sty/leaf-sty.css"
# A styler that was NOT chosen, to prove the sub-axis is a selection.
printf 'template.styling = +./other.css\n' \
	> "$R/themes/leaf/stylers/other/theme-styler.conf"
printf '/* other styler */\n' > "$R/themes/leaf/stylers/other/other.css"
# An engine axis that WAS chosen.
printf 'template.styling = +./leaf-eng.css\n' \
	> "$R/themes/leaf/engines/eng/theme-engine.conf"
printf '/* leaf engine */\n' > "$R/themes/leaf/engines/eng/leaf-eng.css"

# `extends = base` is resolved by SEARCH, the same way --theme is, so the
# fixture root has to be where the search looks. TEMPLATES_DIR is read when
# lib/template.sh is sourced, so it is set here rather than left to follow
# PDFULATOR_DIR.
PDFULATOR_DIR=$R
PDFULATOR_HOME=$R
ENGINES_DIR="$R/engines"
TEMPLATES_DIR="$R/templates"
export PDFULATOR_DIR PDFULATOR_HOME ENGINES_DIR TEMPLATES_DIR

CHAIN=$(theme_chain "$R/themes/leaf")
ok "the chain has all three themes" "3" "$(printf '%s\n' "$CHAIN" | grep -c .)"

P="$BASE/payload"
mkdir -p "$P"
stage_mirror_all "$CHAIN" eng sty "$P" > "$BASE/mirror.log" 2>&1
ok "the mirror succeeds" "0" "$?"

ok "the engine's conf is there"   "yes" "$(has "$P" input/engines/eng/engine.conf)"
ok "the template's conf is there" "yes" "$(has "$P" input/templates/tmpl/template.conf)"
ok "the base theme's conf is there" "yes" "$(has "$P" input/themes/base/theme.conf)"
ok "the leaf theme's conf is there" "yes" "$(has "$P" input/themes/leaf/theme.conf)"

# The one that the old stylesheet-driven mirror could not produce.
ok "a theme contributing no stylesheet is still there" \
   "yes" "$(has "$P" input/themes/mid/theme.conf)"

ok "the chosen styler's conf is there" \
   "yes" "$(has "$P" input/themes/leaf/stylers/sty/theme-styler.conf)"
ok "the chosen engine axis's conf is there" \
   "yes" "$(has "$P" input/themes/leaf/engines/eng/theme-engine.conf)"

# Content, not just conf files: an object's files come whole, because they
# refer to each other in ways only that object's ecosystem understands.
ok "the template's markup comes too" \
   "yes" "$(has "$P" input/templates/tmpl/markup.html)"
ok "the engine's stylesheet comes too" \
   "yes" "$(has "$P" input/engines/eng/engine.css)"


section "and no more than that"

ok "_nopayload does not travel" \
   "no" "$(has "$P" input/engines/eng/_nopayload/main.js)"
ok "a declared exclusion does not travel" \
   "no" "$(has "$P" input/engines/eng/convert)"

# The sub-axis rule: a theme has one directory per styler it knows about, and
# only the chosen one is part of this build. Shipping them all would put CSS
# in the payload that an engine walking the tree has no way to rule out.
ok "an unchosen styler does not travel" \
   "no" "$(has "$P" input/themes/leaf/stylers/other/theme-styler.conf)"
ok "nor does its stylesheet" \
   "no" "$(has "$P" input/themes/leaf/stylers/other/other.css)"


# --- Two sources, one name --------------------------------------------------
#
# The mirror path is <kind>/<name>, so `--theme ./classic` beside a shipped
# themes/classic collides. The second must land elsewhere rather than
# overwrite the first -- and, just as importantly, a directory asked about
# twice must get the SAME answer both times, or a stylesheet ends up in a copy
# of its own object rather than in it.

section "clashes and repeats"

A="$BASE/clash/a/themes/dup"
B="$BASE/clash/b/themes/dup"
mkdir -p "$A" "$B"
printf 'name = a\n' > "$A/theme.conf"
printf 'name = b\n' > "$B/theme.conf"

C="$BASE/clashpayload"
mkdir -p "$C"

first=$(stage_mirror_alloc "$A" "$C")
again=$(stage_mirror_alloc "$A" "$C")
other=$(stage_mirror_alloc "$B" "$C")

ok "the first gets the plain path" "themes/dup" "$first"
# The one that regressed when the object mirror was added: the allocator used
# to ask the filesystem "does this exist yet", and after stage_mirror_object
# had created the directory the answer was yes -- so a directory clashed with
# its own copy and every theme got a `-2` twin.
ok "asking twice gives the same answer" "themes/dup" "$again"
ok "a genuine clash is disambiguated" "themes/dup-2" "$other"


# --- The real tree ----------------------------------------------------------
#
# The fixtures above are shaped to make each rule visible; this checks the
# shipped objects, where a wrong exclusion would be found by users rather than
# by this file.

section "the shipped engines"

REPO=$(cd "$(dirname "$0")/.." && pwd)
for _e in "$REPO"/engines/*/; do
	_id=$(basename "$_e")
	[ -f "$_e/engine.conf" ] || continue
	# convert is the wrapper's entry point and cannot move under _nopayload/,
	# so every engine has to exclude it by name or ship an executable into
	# every container mount.
	case " $(stage_nopayload_list "$_e") " in
		*" convert "*) _r=yes ;;
		*)             _r=no  ;;
	esac
	ok "$_id excludes convert" "yes" "$_r"

	# And keeps the default, which is what `+` is for. An engine that wrote
	# `do.not.payload = convert` would ship its node_modules.
	case " $(stage_nopayload_list "$_e") " in
		*" _nopayload "*) _r=yes ;;
		*)                _r=no  ;;
	esac
	ok "$_id keeps the _nopayload default" "yes" "$_r"
done


# --- The two readers agree -------------------------------------------------
#
# lib/styling.sh resolves the cascade in sh; engines/vivlio/_nopayload/
# payload.js resolves it again in JS, by walking the payload the shell staged.
# Two implementations of one rule is a standing invitation to drift, and drift
# here does not raise an error -- it renders a document with the wrong
# stylesheet order, which only an eye catches.
#
# So the check is that they produce the SAME LIST for the same inputs. The
# fixture is three themes deep with two populated axes, because that is the
# shape where the settled axis-outer order and the rejected chain-outer order
# differ: with two themes, or one axis, both orders give the same answer and
# the test would pass against a wrong implementation.

section "the shell and the engine agree"

if ! command -v bun >/dev/null 2>&1; then
	printf 'skip  no bun; cannot run the JS reader\n'
else
	C="$BASE/cascade"
	mkdir -p "$C/engines/eng" "$C/templates/tmpl"
	printf 'id=eng\ntemplate=tmpl\nstyler=sty\n' > "$C/engines/eng/engine.conf"
	printf 'template.structure = ./markup.html\n' > "$C/templates/tmpl/template.conf"
	printf '<html></html>\n' > "$C/templates/tmpl/markup.html"

	prev=""
	for t in base mid leaf; do
		mkdir -p "$C/themes/$t/stylers/sty"
		{
			printf 'name = %s\n' "$t"
			[ -n "$prev" ] && printf 'extends = %s/themes/%s\n' "$C" "$prev"
			printf 'template.styling = +./%s.css\n' "$t"
		} > "$C/themes/$t/theme.conf"
		printf '/* %s */\n' "$t" > "$C/themes/$t/$t.css"
		# A SECOND sheet on the same object, so that `+` adding and a bare
		# value replacing are distinguishable. With one sheet per object both
		# readings give the same list, and a reader that ignored `+` entirely
		# would pass.
		printf 'template.styling = +./%s-extra.css\n' "$t" \
			>> "$C/themes/$t/theme.conf"
		printf '/* %s extra */\n' "$t" > "$C/themes/$t/$t-extra.css"
		printf 'template.styling = +./%s-sty.css\n' "$t" \
			> "$C/themes/$t/stylers/sty/theme-styler.conf"
		printf '/* %s sty */\n' "$t" > "$C/themes/$t/stylers/sty/$t-sty.css"
		prev=$t
	done

	CHAIN=$(PDFULATOR_DIR="$C" TEMPLATES_DIR="$C/templates" theme_chain "$C/themes/leaf")

	# The shell's answer: basenames, in cascade order.
	SH=$(PDFULATOR_DIR="$C" TEMPLATES_DIR="$C/templates" ENGINES_DIR="$C/engines" \
		styling_list "$CHAIN" eng sty "$C/engines/eng" "" |
		while IFS="$(printf '\t')" read -r _l _f || [ -n "$_l" ]; do
			[ -n "$_f" ] || continue
			basename -- "$_f"
		done | tr '\n' ' ' | sed 's/ $//')

	ok "the shell resolves axis-outer, chain-inner" \
	   "base.css base-extra.css mid.css mid-extra.css leaf.css leaf-extra.css base-sty.css mid-sty.css leaf-sty.css" "$SH"

	# Stage it, then ask the JS reader the same question of the result.
	P2="$BASE/cascade-payload"
	mkdir -p "$P2"
	PDFULATOR_DIR="$C" TEMPLATES_DIR="$C/templates" ENGINES_DIR="$C/engines" \
		stage_mirror_all "$CHAIN" eng sty "$P2" >/dev/null 2>&1

	cat > "$BASE/ask.mjs" <<JSEOF
import { stylesheets, markup, engineOf } from '$REPO/engines/vivlio/_nopayload/payload.js';
const P = '$P2';
const { id, styler } = engineOf(P);
console.log([id, styler].join(' '));
console.log(stylesheets(P, id, styler).map(s => s.split('/').pop()).join(' '));
console.log((markup(P) || '').split('/').pop());
JSEOF

	JS=$(bun run "$BASE/ask.mjs" 2>"$BASE/ask.err")
	ok "the JS reader runs" "0" "$?"

	ok "it reads the engine and styler from the payload" "eng sty" \
	   "$(printf '%s\n' "$JS" | sed -n 1p)"

	# THE POINT OF THIS SECTION.
	ok "and resolves the same cascade the shell did" "$SH" \
	   "$(printf '%s\n' "$JS" | sed -n 2p)"

	ok "and finds the declared markup, not a fixed name" "markup.html" \
	   "$(printf '%s\n' "$JS" | sed -n 3p)"

	# And the third implementation: _lib/payload.sh, which is what a
	# containerised engine runs. It ships INSIDE the payload precisely so that
	# it cannot be a different revision from the wrapper that built it -- but
	# that guarantee is about packaging, and says nothing about whether the
	# code agrees. This is where that is checked.
	# PDFULATOR_LIB, because PDFULATOR_DIR points at the fixture root here and
	# the reader being tested is the repository's.
	PDFULATOR_LIB="$REPO/lib" stage_lib "$P2" || :
	SH2=$(sh "$P2/_lib/payload.sh" stylesheets "$P2" |
		while IFS= read -r _f || [ -n "$_f" ]; do
			[ -n "$_f" ] || continue
			basename -- "$_f"
		done | tr '\n' ' ' | sed 's/ $//')

	ok "the payload's own reader agrees too" "$SH" "$SH2"
	ok "and finds the same markup" "markup.html" \
	   "$(basename -- "$(sh "$P2/_lib/payload.sh" markup "$P2")")"
	ok "and reads the engine and styler" "eng sty" \
	   "$(sh "$P2/_lib/payload.sh" engine "$P2")"

	# Paths are printed RELATIVE to the payload, so an engine that sees it
	# through a container mount at /payload can use them unchanged. An absolute
	# path here would name a directory that does not exist inside the container.
	ok "paths are relative to the payload" "no" \
	   "$(sh "$P2/_lib/payload.sh" stylesheets "$P2" | grep -q '^/' && echo yes || echo no)"
fi


printf '\n'
if [ "$FAIL" = 0 ]; then
	printf 'ALL EXPECTATIONS MET\n'
else
	printf 'EXPECTATIONS NOT MET\n'
fi
exit $FAIL
