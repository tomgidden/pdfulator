#!/bin/sh
# Template matrix.
#
# A template is the third object type, and it exists because "the template" is
# not one thing: vivlio fills a Mustache file, pandoc-pagedjs fills an HTML
# file in pandoc's own $var$ syntax, pandoc-xslt fills a DocBook 5 one in that
# same syntax. Those groupings follow neither `parser` nor `styler`.
#
# The bug it fixes is worth stating, because most of these cases are aimed at
# it: templates used to be staged by *filename*, so themes/default's Mustache
# article.tmpl was copied into the directory handed to pandoc, which does not
# know that syntax and printed the markup into the PDF as literal text. The two
# files are nearly identical and differ only in their placeholders, so nothing
# errored -- the output was simply wrong, which is the failure mode worth
# testing hardest.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/conf.sh"
. "$LIB/paths.sh"
. "$LIB/theme.sh"
. "$LIB/template.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-templatematrix
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

# Two ecosystems whose structural files have the SAME NAME and incompatible
# syntax -- the situation the object type exists to keep straight.
setup() {
	rm -rf "$BASE"
	mkdir -p "$BASE/templates/mustache" "$BASE/templates/pandoc" \
	         "$BASE/engines/viv" "$BASE/engines/pan" "$BASE/engines/bare" \
	         "$BASE/themes/base" "$BASE/themes/derived"

	echo 'MUSTACHE' > "$BASE/templates/mustache/article.tmpl"
	echo 'PANDOC'   > "$BASE/templates/pandoc/article.tmpl"
	printf 'template.structure = ./article.tmpl\n' \
		> "$BASE/templates/mustache/template.conf"
	printf 'template.structure = ./article.tmpl\n' \
		> "$BASE/templates/pandoc/template.conf"

	printf 'styler=vivliostyle\ntemplate=mustache\n' \
		> "$BASE/engines/viv/engine.conf"
	printf 'styler=pagedjs\ntemplate=pandoc\n' \
		> "$BASE/engines/pan/engine.conf"
	printf 'styler=none\n' > "$BASE/engines/bare/engine.conf"

	printf 'extends = base\n' > "$BASE/themes/derived/theme.conf"

	PDFULATOR_DIR="$BASE"
	TEMPLATES_DIR="$BASE/templates"
	ENGINES_DIR="$BASE/engines"
	PDFULATOR_HOME="$BASE/home"
}

chain_of() { theme_chain "$BASE/themes/$1"; }


section "CONF_GET_ALL"

setup
printf 'a = one\na = +two\nb = other\na = +three\n' > "$BASE/multi.conf"

# The list reader takes every occurrence, in file order. conf_get's contract is
# the opposite and is relied on all over the wrapper, which is why this is a
# second function rather than a flag.
ok "every occurrence is returned" "one +two +three" \
	"$(conf_get_all "$BASE/multi.conf" a | tr '\n' ' ' | sed 's/ $//')"
ok "conf_get is unchanged and takes the first" "one" \
	"$(conf_get "$BASE/multi.conf" a)"
ok "an absent key is an empty list, not a blank line" "0" \
	"$(conf_get_all "$BASE/multi.conf" nope | wc -l | tr -d ' ')"

# The `+` stays on the value. Whether it means "add" depends on what the caller
# is accumulating, and stripping it here would make the two spellings
# indistinguishable to the one place that has to tell them apart.
ok "the + is left on the value" "yes" \
	"$(conf_get_all "$BASE/multi.conf" a | sed -n 2p | \
	   grep -q '^+' && echo yes || echo no)"

# A key set to nothing contributes nothing: `template.styling =` means "no
# styling", not "add the empty filename", which would resolve to the config
# file's own directory and be read as a stylesheet.
printf 'a = one\na =\na = +two\n' > "$BASE/empty.conf"
ok "an empty value adds nothing to the list" "2" \
	"$(conf_get_all "$BASE/empty.conf" a | wc -l | tr -d ' ')"

ok "a missing file is distinguishable" "1" \
	"$(conf_get_all "$BASE/nosuch.conf" a >/dev/null 2>&1; echo $?)"


section "TEMPLATE SELECTION"

setup
c=$(chain_of derived)

ok "an engine's declared template is found" "$BASE/templates/mustache" \
	"$(template_select "$c" viv vivliostyle "$BASE/engines/viv")"

# The heart of it: same theme, same filename, different ecosystem.
ok "a different engine selects a different template" "$BASE/templates/pandoc" \
	"$(template_select "$c" pan pagedjs "$BASE/engines/pan")"

# An engine naming none is not an error -- it falls back to whatever built-in
# it carries, which is what the null engine does and what a future `remote`
# engine with no template concept will do.
ok "an engine with no template selects nothing" "" \
	"$(template_select "$c" bare none "$BASE/engines/bare")"
ok "and that is not a failure" "0" \
	"$(template_select "$c" bare none "$BASE/engines/bare" >/dev/null 2>&1; echo $?)"


section "THEME OVERRIDES"

# A theme may override the template, though it is expected to be rare: the
# template belongs to the engine's ecosystem, and a theme changing it is
# claiming to know that ecosystem better than the engine does.
setup
printf 'extends = base\ntemplate = pandoc\n' > "$BASE/themes/derived/theme.conf"
c=$(chain_of derived)
ok "a theme's theme.conf beats the engine" "$BASE/templates/pandoc" \
	"$(template_select "$c" viv vivliostyle "$BASE/engines/viv")"

# Child beats parent, as every other theme key already behaves.
setup
printf 'template = pandoc\n'   > "$BASE/themes/base/theme.conf"
printf 'extends = base\ntemplate = mustache\n' \
	> "$BASE/themes/derived/theme.conf"
c=$(chain_of derived)
ok "the most derived theme wins" "$BASE/templates/mustache" \
	"$(template_select "$c" viv vivliostyle "$BASE/engines/viv")"

# Within one theme: engine beats styler beats plain, the same specificity order
# theme_file uses for every other file.
setup
mkdir -p "$BASE/themes/derived/stylers/vivliostyle" \
         "$BASE/themes/derived/engines/viv"
printf 'extends = base\ntemplate = mustache\n' \
	> "$BASE/themes/derived/theme.conf"
printf 'template = pandoc\n' \
	> "$BASE/themes/derived/stylers/vivliostyle/theme-styler.conf"
c=$(chain_of derived)
ok "theme-styler.conf beats theme.conf" "$BASE/templates/pandoc" \
	"$(template_select "$c" viv vivliostyle "$BASE/engines/viv")"

printf 'template = mustache\n' \
	> "$BASE/themes/derived/engines/viv/theme-engine.conf"
ok "theme-engine.conf beats theme-styler.conf" "$BASE/templates/mustache" \
	"$(template_select "$c" viv vivliostyle "$BASE/engines/viv")"

# A styler override must not leak to an engine of another styler. Tested with
# no plain theme.conf template, so that a leak is the only thing that could
# produce the styler's answer -- with one present, falling through to it gives
# the same result for the wrong reason.
setup
mkdir -p "$BASE/themes/derived/stylers/vivliostyle"
printf 'extends = base\n' > "$BASE/themes/derived/theme.conf"
printf 'template = mustache\n' \
	> "$BASE/themes/derived/stylers/vivliostyle/theme-styler.conf"
c=$(chain_of derived)
ok "a vivliostyle override reaches a vivliostyle engine" \
	"$BASE/templates/mustache" \
	"$(template_select "$c" viv vivliostyle "$BASE/engines/viv")"
ok "and does not reach a pagedjs engine" "$BASE/templates/pandoc" \
	"$(template_select "$c" pan pagedjs "$BASE/engines/pan")"


section "REFERENCES AND STRUCTURE"

setup

# A bare name is looked up in TEMPLATES_DIR, so `template = mustache` works
# from anywhere. A reference containing a slash is a path, relative to the file
# that wrote it -- the same name-versus-path split theme_resolve makes.
ok "a bare name resolves against TEMPLATES_DIR" "$BASE/templates/mustache" \
	"$(template_resolve mustache "$BASE/engines/viv")"
ok "a relative path resolves against the naming file" "$BASE/templates/pandoc" \
	"$(template_resolve ../../templates/pandoc "$BASE/engines/viv")"
ok "an absolute path is taken as given" "$BASE/templates/pandoc" \
	"$(template_resolve "$BASE/templates/pandoc" "$BASE/engines/viv")"

# A named template that is not there is an error, not a silent fallback to a
# different one -- the same rule as a missing theme or a missing font. Quietly
# using something else is how the wrong thing ships.
ok "a missing template fails" "1" \
	"$(template_resolve nosuch "$BASE/engines/viv" >/dev/null 2>&1; echo $?)"

ok "the structure is resolved to an absolute path" \
	"$BASE/templates/mustache/article.tmpl" \
	"$(template_structure "$BASE/templates/mustache")"
ok "and staged under its own basename" "article.tmpl" \
	"$(template_structure_name "$BASE/templates/mustache")"

# A structure the template names but does not have is an error for the same
# reason: it would otherwise stage nothing and fall back to a built-in that
# looks almost right.
printf 'template.structure = ./missing.tmpl\n' \
	> "$BASE/templates/mustache/template.conf"
ok "a named structure that is absent fails" "1" \
	"$(template_structure "$BASE/templates/mustache" >/dev/null 2>&1; echo $?)"

# A template may carry styling alone and declare no structure at all.
printf '# nothing\n' > "$BASE/templates/mustache/template.conf"
ok "a template with no structure is not an error" "0" \
	"$(template_structure "$BASE/templates/mustache" >/dev/null 2>&1; echo $?)"
ok "and stages nothing" "" \
	"$(template_structure "$BASE/templates/mustache")"


section "SUPPORT FILES"

# A structural file is not always self-contained: the DocBook template pulls in
# global.ent through a SYSTEM entity, which resolves relative to the template's
# own location. Staging the template alone gives pandoc a DTD subset pointing
# at a file that is not there, and the parse fails before any conversion.
setup
printf 'x\n' > "$BASE/templates/mustache/one.ent"
printf 'y\n' > "$BASE/templates/mustache/two.ent"
{
	printf 'template.structure = ./article.tmpl\n'
	printf 'template.support = ./one.ent\n'
	printf 'template.support = ./two.ent\n'
} > "$BASE/templates/mustache/template.conf"

# Every occurrence counts: a template may need more than one, and there is no
# sensible reading in which a second declaration replaces the first.
ok "every support file is listed" "2" \
	"$(template_support "$BASE/templates/mustache" | wc -l | tr -d ' ')"
ok "support paths are absolute" "yes" \
	"$(template_support "$BASE/templates/mustache" | head -1 | \
	   grep -q '^/' && echo yes || echo no)"

# Absent is an error, not a silent omission -- the failure it prevents happens
# later, inside the engine, and names the entity rather than the template.
printf 'template.structure = ./article.tmpl\ntemplate.support = ./nosuch.ent\n' \
	> "$BASE/templates/mustache/template.conf"
ok "a missing support file fails" "1" \
	"$(template_support "$BASE/templates/mustache" >/dev/null 2>&1; echo $?)"

# Declaring none is the ordinary case.
printf 'template.structure = ./article.tmpl\n' \
	> "$BASE/templates/mustache/template.conf"
ok "no support files is not an error" "0" \
	"$(template_support "$BASE/templates/mustache" >/dev/null 2>&1; echo $?)"

# The shipped DocBook template must actually declare its entity file. This is
# the case that motivated the mechanism, so it is asserted on the real tree.
ok "docbook5-pandoc declares global.ent" "yes" \
	"$(TEMPLATES_DIR=$(cd "$(dirname "$0")/../templates" && pwd); \
	   template_support "$TEMPLATES_DIR/docbook5-pandoc" 2>/dev/null | \
	   grep -q 'global\.ent' && echo yes || echo no)"


section "THE SHIPPED TREE"

# The real engines, not fixtures. Every engine that declares a template must
# resolve to one that exists and has the structure it claims -- otherwise the
# staged directory silently lacks a template and the engine falls back to a
# built-in, which is the failure this whole object type exists to prevent.
REPO=$(cd "$(dirname "$0")/.." && pwd)
PDFULATOR_DIR="$REPO"
TEMPLATES_DIR="$REPO/templates"
ENGINES_DIR="$REPO/engines"
rc=$(theme_chain "$REPO/themes/default" >/dev/null 2>&1; echo $?)
ok "the default theme's chain resolves" "0" "$rc"
rchain=$(theme_chain "$REPO/themes/default")

for e in vivlio vivlio-docker pandoc-pagedjs pandoc-xslt; do
	s=$(conf_get "$REPO/engines/$e/engine.conf" styler)
	t=$(template_select "$rchain" "$e" "$s" "$REPO/engines/$e") || t=""
	ok "$e selects a template" "yes" \
		"$([ -n "$t" ] && echo yes || echo no)"
	f=$(template_structure "$t" 2>/dev/null) || f=""
	ok "$e's structure exists" "yes" \
		"$([ -n "$f" ] && [ -f "$f" ] && echo yes || echo no)"
done

# The syntax check that names the bug. The vivlio engines must get Mustache
# placeholders and the pandoc ones must not -- asserted on the real files,
# because this is the pairing that was wrong in every shipped release.
vt=$(template_structure "$(template_select "$rchain" vivlio vivliostyle \
	"$REPO/engines/vivlio")")
pt=$(template_structure "$(template_select "$rchain" pandoc-pagedjs pagedjs \
	"$REPO/engines/pandoc-pagedjs")")
ok "vivlio's template is Mustache" "yes" \
	"$(grep -q '{{' "$vt" && echo yes || echo no)"
ok "pandoc-pagedjs's template is not Mustache" "no" \
	"$(grep -q '{{' "$pt" && echo yes || echo no)"
ok "pandoc-pagedjs's template is pandoc syntax" "yes" \
	"$(grep -q '\$title\$' "$pt" && echo yes || echo no)"
ok "and the two are different files" "no" \
	"$([ "$vt" = "$pt" ] && echo yes || echo no)"

# The theme tree must no longer carry a structural template of its own. This is
# the regression guard: putting article.tmpl back into themes/default is
# exactly what reintroduces the bug, and it would look like a tidy-up.
ok "no theme ships a structural template" "0" \
	"$(find "$REPO/themes" -name '*.tmpl' | wc -l | tr -d ' ')"


printf '\n'
if [ "$FAIL" = 0 ]; then
	printf 'All template checks passed.\n'
else
	printf 'Some template checks FAILED.\n'
fi
exit "$FAIL"
