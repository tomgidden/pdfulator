#!/bin/sh
# The pandoc-pagedjs engine's in-container render step.
#
# `render` is what runs *inside* the image, so testing it normally means
# building a 700MB image and starting a container per case. It doesn't have
# to: the script's job is to assemble two command lines -- one for pandoc, one
# for pagedjs-cli -- and to get the file handling around them right. Stubs
# that record their arguments test exactly that, in milliseconds, on a machine
# with no Docker.
#
# What this deliberately does not test is whether pandoc and Paged.js produce
# a good PDF. That needs the real tools and is answered by building the image
# and running a document through it.
#
# The cases matter because this pipeline has traps the vivlio one does not:
# pandoc takes a YAML sidecar as a second *input file* rather than as an
# option, and the order of those files decides which metadata wins.
REPO=$(cd "$(dirname "$0")/.." && pwd)
RENDER=$REPO/engines/pandoc-pagedjs/_nopayload/render

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-pandocmatrix.$$
FAIL=0
trap 'rm -rf "$BASE"' EXIT INT TERM

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

# The image's layout, rebuilt in a temporary directory: /defaults, /engine,
# /theme and /work become $BASE/... and the stubs stand in for the tools.
#
# The script hardcodes those absolute paths, as it should -- they are fixed by
# its own Dockerfile, and making them configurable would be inventing a
# variable no user can set. So the test runs it with the paths rewritten,
# which is the one thing here that is not the shipped file.
fixture() {
	rm -rf "$BASE"
	mkdir -p "$BASE/engine" "$BASE/theme" "$BASE/work" \
	         "$BASE/bin" "$BASE/in" "$BASE/out"

	printf 'template\n'  > "$BASE/engine/article.tmpl"
	printf '%s\n' '-- filter' > "$BASE/engine/metadata.lua"
	# The theme arrives staged: the wrapper has already concatenated the CSS
	# cascade and generated the @font-face rules, so the engine sees two plain
	# files rather than a theme it has to resolve anything about.
	printf 'body{}\n'    > "$BASE/theme/print.css"
	printf ':root{}\n'   > "$BASE/theme/fonts.css"

	printf '# A document\n\nBody text.\n' > "$BASE/in/doc.md"

	# Stubs. Each records its whole command line, one argument per line, so an
	# assertion can look for an exact argument rather than a substring.
	cat > "$BASE/bin/pandoc" <<'STUB'
#!/bin/sh
for _a in "$@"; do printf '%s\n' "$_a"; done >> "$PANDOC_LOG"
# Write the -o target, so the next stage has something to find.
_prev=""
for _a in "$@"; do
	if [ "$_prev" = "-o" ]; then printf '<html></html>\n' > "$_a"; fi
	_prev=$_a
done
exit 0
STUB
	cat > "$BASE/bin/pagedjs-cli" <<'STUB'
#!/bin/sh
for _a in "$@"; do printf '%s\n' "$_a"; done >> "$PAGEDJS_LOG"
_prev=""
for _a in "$@"; do
	if [ "$_prev" = "-o" ]; then printf '%%PDF-1.4\nstub\n' > "$_a"; fi
	_prev=$_a
done
exit 0
STUB
	chmod +x "$BASE/bin/pandoc" "$BASE/bin/pagedjs-cli"

	# The shipped script with its container paths pointed at the fixture.
	sed -e "s|^ENGINE=/engine|ENGINE=$BASE/engine|" \
	    -e "s|/work/pdfulator|$BASE/work/pdfulator|" \
	    "$RENDER" > "$BASE/render"
	chmod +x "$BASE/render"

	PANDOC_LOG="$BASE/pandoc.log"; : > "$PANDOC_LOG"
	PAGEDJS_LOG="$BASE/pagedjs.log"; : > "$PAGEDJS_LOG"
	export PANDOC_LOG PAGEDJS_LOG
	PATH="$BASE/bin:$PATH"; export PATH
}

run() {  # run <in> <out> <theme>
	( cd "$BASE" && "$BASE/render" "$1" "$2" "$3" >"$BASE/stdout" 2>"$BASE/err" )
}

# Exact-argument test. `-e --` because most of what is looked for starts with a
# dash, and grep reads a leading-dash pattern given positionally as its own
# option.
haslog() {  # haslog <logfile> <argument>
	grep -qxF -e "$2" "$1" && echo yes || echo no
}

# The nth argument in a log, 1-indexed.
argn() {  # argn <logfile> <n>
	sed -n "$2p" "$1"
}


echo "============ PANDOC INVOCATION ============"
fixture
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"

# commonmark_x, not pandoc's own markdown dialect: it is CommonMark plus a
# curated extension set, so a document that renders elsewhere renders here.
# -raw_html because this pipeline prints to paper, and embedded HTML is a way
# to smuggle in layout the stylesheet cannot then control.
check "the format is v1's" "yes" \
      "$(haslog "$PANDOC_LOG" "commonmark_x-raw_html+task_lists+definition_lists")"
check "output is html5" "yes" "$(haslog "$PANDOC_LOG" "html5")"
# The stylesheet does its own code styling; pandoc's inline highlighting would
# fight it with hardcoded colours.
check "highlighting is off" "yes" "$(haslog "$PANDOC_LOG" "--no-highlight")"
check "the engine's template is used" "yes" \
      "$(haslog "$PANDOC_LOG" "--template=$BASE/engine/article.tmpl")"
check "the engine's filter is used" "yes" \
      "$(haslog "$PANDOC_LOG" "--lua-filter=$BASE/engine/metadata.lua")"


echo "============ SIDECAR ============"
# A sidecar goes in as --metadata-file, NOT as a second input file.
#
# v1 passed it as an input, and this engine first reproduced that. It is
# wrong in a way that produces a plausible PDF: pandoc reads YAML from an
# input file only when it is fenced with --- and ..., and a sidecar is not,
# so an unfenced one is parsed as *markdown* and its text is rendered into
# the body -- "title: My Report authors: name: Tom" printed as a paragraph,
# with the document's title unchanged. Fencing it does not help, because
# commonmark_x has no YAML metadata block extension and drops the values.
#
# Found by rendering a document with a sidecar and reading the output, not by
# checking that the command succeeded -- it always did.
fixture
printf 'title: From the sidecar\n' > "$BASE/in/doc.yaml"
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check "a .yaml sidecar becomes --metadata-file" "yes" \
      "$(grep -q -- '--metadata-file=.*doc\.yaml$' "$PANDOC_LOG" && echo yes || echo no)"
# The assertion that matters: it must not appear as a bare input path, which
# is what put its text in the body.
check "and is not a second input file" "no" \
      "$(grep -qx "/.*/doc\.yaml" "$PANDOC_LOG" && echo yes || echo no)"
check "the document is the only input" "1" \
      "$(grep -cx "/.*/doc\.md" "$PANDOC_LOG")"

fixture
printf 'title: From a .yml\n' > "$BASE/in/doc.yml"
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check ".yml is a sidecar too" "yes" \
      "$(grep -q -- '--metadata-file=.*doc\.yml$' "$PANDOC_LOG" && echo yes || echo no)"

fixture
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check "no sidecar, no --metadata-file" "no" \
      "$(grep -q -- '--metadata-file' "$PANDOC_LOG" && echo yes || echo no)"

# stdin has no sidecar to find -- there is no path to look beside.
fixture
printf '# Piped\n' | ( cd "$BASE" && "$BASE/render" - - "$BASE/theme" >/dev/null 2>&1 )
check "stdin has no sidecar" "no" \
      "$(grep -q -- '--metadata-file' "$PANDOC_LOG" && echo yes || echo no)"


echo "============ THEME OVERRIDES ============"
# The *staged* template wins. Not "a theme's own article.tmpl wins", which is
# what this asserted before and what was wrong: staging used to copy a file
# called article.tmpl out of the theme chain regardless of its syntax, so
# themes/default's Mustache template reached pandoc and its markup was printed
# into the PDF as text. The wrapper now selects a template by ecosystem and
# stages it under this name, so what is here is always pandoc's dialect.
#
# The assertion itself is unchanged in shape because the engine's rule is
# unchanged -- prefer the staged copy -- and that rule was never the bug. What
# changed is who is allowed to put a file here.
fixture
printf 'staged template\n' > "$BASE/theme/article.tmpl"
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check "the staged template wins" "yes" \
      "$(haslog "$PANDOC_LOG" "--template=$BASE/theme/article.tmpl")"
check "and the engine's is not also passed" "no" \
      "$(haslog "$PANDOC_LOG" "--template=$BASE/engine/article.tmpl")"

# A staged directory with no template at all falls back to the engine's own,
# which is what a bare `docker run` with no mounts gets.
fixture
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check "no staged template falls back to the engine's" "yes" \
      "$(haslog "$PANDOC_LOG" "--template=$BASE/engine/article.tmpl")"

fixture
printf '%s\n' '-- theme filter' > "$BASE/theme/metadata.lua"
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
# Both filters run, deliberately: the engine's hoists the title and fills in
# the year, and a theme's adds to that rather than reimplementing it.
check "a theme filter is added" "yes" \
      "$(haslog "$PANDOC_LOG" "--lua-filter=$BASE/theme/metadata.lua")"
check "the engine's filter still runs" "yes" \
      "$(haslog "$PANDOC_LOG" "--lua-filter=$BASE/engine/metadata.lua")"

# A theme with no template and no filter is the common case, and must not be
# an error. Under `set -e` a bare `[ -f ... ] && VAR=...` whose test fails is
# a failing command -- the shape that silently aborted browser_gather.
fixture
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check "a bare theme is not an error" "yes" \
      "$([ -s "$BASE/out/doc.pdf" ] && echo yes || echo no)"


echo "============ PAGEDJS INVOCATION ============"
fixture
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
# Not optional in a container: --no-sandbox because Chromium's sandbox needs
# privileges a default `docker run` does not grant, and --disable-dev-shm-usage
# because /dev/shm defaults to 64MB, which a paginating renderer exhausts on a
# document of any size -- crashing in a way that reads as a Paged.js failure
# rather than as a full filesystem.
check "container browser flags are passed" "yes" \
      "$(haslog "$PAGEDJS_LOG" "--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage")"
check "pagedjs reads pandoc's html" "yes" \
      "$(grep -q '\.html$' "$PAGEDJS_LOG" && echo yes || echo no)"


echo "============ STREAMS ============"
fixture
printf '# Piped\n\nFrom stdin.\n' | ( cd "$BASE" && "$BASE/render" - - "$BASE/theme" > "$BASE/piped.pdf" 2>/dev/null )
check "stdin to stdout emits a PDF" "yes" \
      "$(head -c 5 "$BASE/piped.pdf" 2>/dev/null | grep -q '%PDF-' && echo yes || echo no)"

# Empty *stdin* is an error; an empty *file* is not. The asymmetry is
# deliberate and shared with the vivlio engine: a pipe that produced nothing
# is a broken command line, while an empty document is one someone has started
# and not yet written. See [[pdfulator-behaviour-traps]].
fixture
printf '' | ( cd "$BASE" && "$BASE/render" - - "$BASE/theme" >/dev/null 2>"$BASE/err" )
check "empty stdin is refused" "1" "$?"
check "and says so" "yes" \
      "$(grep -q 'empty input on stdin' "$BASE/err" && echo yes || echo no)"

fixture
: > "$BASE/in/empty.md"
run "$BASE/in/empty.md" "$BASE/out/empty.pdf" "$BASE/theme"
check "an empty file is not refused" "yes" \
      "$([ -s "$BASE/out/empty.pdf" ] && echo yes || echo no)"

fixture
run "$BASE/in/nope.md" "$BASE/out/x.pdf" "$BASE/theme"
check "a missing input fails" "1" "$?"


echo "============ OUTPUT ============"
fixture
run "$BASE/in/doc.md" "$BASE/out/sub/deep/doc.pdf" "$BASE/theme"
check "a missing output directory is created" "yes" \
      "$([ -f "$BASE/out/sub/deep/doc.pdf" ] && echo yes || echo no)"

# The PDF is assembled in the scratch directory and moved, so an interrupted
# run cannot leave a half-written file that still looks like a PDF.
fixture
run "$BASE/in/doc.md" "$BASE/out/doc.pdf" "$BASE/theme"
check "the output is a PDF" "yes" \
      "$(head -c 5 "$BASE/out/doc.pdf" | grep -q '%PDF-' && echo yes || echo no)"

# The scratch directory goes, unless debugging. A container is discarded
# anyway, but `pdfulator -d` is how someone inspects the intermediate HTML.
check "the scratch directory is cleaned up" "0" \
      "$(ls "$BASE/work" 2>/dev/null | wc -l | tr -d ' ')"

fixture
( cd "$BASE" && PDFULATOR_DEBUG=1 "$BASE/render" "$BASE/in/doc.md" \
	"$BASE/out/doc.pdf" "$BASE/theme" >/dev/null 2>&1 )
check "debug keeps it" "1" \
      "$(ls "$BASE/work" 2>/dev/null | wc -l | tr -d ' ')"


echo "============ SET -E ============"
# render sets -e itself. The theme-override tests above are the ones at risk:
# a theme without an article.tmpl is the normal case, and `[ -f ] && VAR=` on
# a false test is a failing command.
fixture
sh -c "set -e; PATH='$BASE/bin:$PATH' PANDOC_LOG='$PANDOC_LOG' \
       PAGEDJS_LOG='$PAGEDJS_LOG' '$BASE/render' '$BASE/in/doc.md' \
       '$BASE/out/doc.pdf' '$BASE/theme'" >/dev/null 2>&1
check "render survives set -e" "0" "$?"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
