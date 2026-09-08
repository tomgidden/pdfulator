#!/bin/sh
# Frontmatter matrix.
#
# Splitting a document into body and metadata: which blocks are recognised,
# which are deliberately not, and what survives the split.
#
# The cases that matter are the ones that must NOT split. A `---` is a
# horizontal rule as often as it is a fence, so every rule below is really an
# answer to "how do you tell somebody's rule from somebody's metadata?" --
# and getting that wrong does not fail, it eats a paragraph or renders a
# metadata block as body text.
#
# This file parses no YAML and neither does lib/frontmatter.sh: it copies two
# halves out verbatim and leaves the actual parsing to js-yaml or pandoc. So
# the assertions are on line ranges and content, never on values.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/frontmatter.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-frontmattermatrix
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

fixture() { rm -rf "$BASE"; mkdir -p "$BASE"; }

# split <file> -- runs the split and reports "split" or "asis"
split() {
	frontmatter_split "$1" "$BASE/body.md" "$BASE/meta.yaml" \
		&& echo split || echo asis
}
meta() { tr '\n' '|' < "$BASE/meta.yaml"; }
body() { tr '\n' '|' < "$BASE/body.md"; }


echo "============ THE THREE-DASH FORM ============"
fixture
printf -- '---\ntitle: T\n---\n\nBody.\n' > "$BASE/a.md"
check "a leading --- block splits"  "split"      "$(split "$BASE/a.md")"
check "the metadata is the block"   "title: T|"  "$(meta)"
check "and the fences are gone"     "|Body.|"    "$(body)"

# `...` closes a YAML document as well as `---` does, and pandoc honours it.
fixture
printf -- '---\ntitle: T\n...\n\nBody.\n' > "$BASE/a.md"
check "... closes the block too"    "title: T|"  "$(split "$BASE/a.md" >/dev/null; meta)"


echo "============ THE COMMENT FORM ============"
# So that a README carrying pdfulator metadata does not show a YAML block when
# GitHub renders it. Other tools see an ordinary HTML comment.
fixture
printf -- '<!--yaml\ntitle: T\n-->\n\nBody.\n' > "$BASE/a.md"
check "a <!--yaml block splits"     "split"      "$(split "$BASE/a.md")"
check "the metadata is the block"   "title: T|"  "$(meta)"
check "and the comment is gone"     "|Body.|"    "$(body)"


echo "============ WHAT MUST NOT SPLIT ============"
# The whole point. Each of these looks like frontmatter to a careless matcher.

# A horizontal rule mid-document. The block is found at the TOP and must stop
# at the first closing fence, not run on to the rule further down.
fixture
printf -- '---\ntitle: T\n---\n\nBody:\n\n---\n\nMore.\n' > "$BASE/a.md"
split "$BASE/a.md" >/dev/null
check "a later rule does not extend the block" "title: T|" "$(meta)"
check "and stays in the body"                  "yes" \
      "$(grep -qx -- '---' "$BASE/body.md" && echo yes || echo no)"

# Frontmatter at the END. Pandoc's native reader accepts a metadata block
# anywhere; commonmark_x -- PFM's base -- does not, and neither does Jekyll,
# Hugo, MultiMarkdown, Obsidian or any static-site generator. Supporting it
# would render correctly here and silently lose the metadata everywhere else.
# It was implemented, tested, and removed on purpose.
fixture
printf -- 'Body.\n\n---\ntitle: T\n---\n' > "$BASE/a.md"
check "a trailing block is NOT metadata" "asis" "$(split "$BASE/a.md")"
check "and nothing is extracted"         ""     "$(meta)"

# A document that merely opens with a rule, with no closing fence anywhere.
fixture
printf -- '---\n\nJust a document that starts with a rule.\n' > "$BASE/a.md"
check "an unterminated block is not metadata" "asis" "$(split "$BASE/a.md")"

# No frontmatter at all, but a line that looks like a key.
fixture
printf -- '# Heading\n\ntitle: not metadata\n' > "$BASE/a.md"
check "a key-shaped line in the body is not metadata" "asis" "$(split "$BASE/a.md")"
check "and the body is untouched" "# Heading||title: not metadata|" "$(body)"


echo "============ WHAT SURVIVES THE SPLIT ============"
# This file does not parse YAML, so anything YAML-shaped must come through
# byte for byte -- nesting, quoting and all. These would each break a naive
# line-oriented extractor.
fixture
printf -- '---\ntitle: "a: colon"\n---\n\nB.\n' > "$BASE/a.md"
split "$BASE/a.md" >/dev/null
check "a quoted colon survives" 'title: "a: colon"|' "$(meta)"

fixture
printf -- '---\nauthors:\n- name: Tom\n  email: t@x\n---\n\nB.\n' > "$BASE/a.md"
split "$BASE/a.md" >/dev/null
check "a nested list survives" 'authors:|- name: Tom|  email: t@x|' "$(meta)"

# CRLF, because a document written on Windows is not a malformed one.
fixture
printf -- '---\r\ntitle: T\r\n---\r\n\r\nB.\r\n' > "$BASE/a.md"
check "CRLF fences are recognised" "split" "$(split "$BASE/a.md")"


echo "============ THE EMPTY CASES ============"
fixture
printf -- '---\n---\n\nB.\n' > "$BASE/a.md"
check "an empty block is still a block" "split" "$(split "$BASE/a.md")"
check "with empty metadata"             ""      "$(meta)"

fixture
: > "$BASE/a.md"
check "an empty file does not split" "asis" "$(split "$BASE/a.md")"


if [ "$FAIL" = 0 ]; then
	echo
	echo "ALL EXPECTATIONS MET"
else
	echo
	echo "FAILURES"
	exit 1
fi
