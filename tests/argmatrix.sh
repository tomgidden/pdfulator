#!/bin/bash
# Argument-handling matrix for pdfulator.
#
# Model under test:
#   pdfulator in.md  [out.pdf]     file -> file
#   pdfulator dir/   [outdir/]     dir  -> dir
#   pdfulator                      cwd
#
# Each case runs in a freshly built fixture so results can't leak between them.

REPO=$(cd "$(dirname "$0")/.." && pwd)
J=$REPO/pdfulator.js
export CHROME_PATH="${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BASE=${TMPDIR:-/tmp}/pdfulator-argmatrix
FAIL=0

fixture() {
	rm -rf "$BASE"; mkdir -p "$BASE"; cd "$BASE" || exit 1
	for n in a b c; do printf '# Doc %s\n\nBody of %s.\n' "$n" "$n" > "$n.md"; done
	printf '%%PDF-1.4\n%%real enough\n'          > real.pdf   # PDF by content
	printf '# Actually markdown\n\nDespite it.\n' > liar.pdf   # .pdf, not a PDF
	mkdir -p src && for n in x y; do printf '# %s\n\nIn src.\n' "$n" > "src/$n.md"; done
	mkdir -p existing-out
	: > empty.md
	: > empty.pdf
	mkdir -p emptydir
}

# run "<expect ok|fail>" <args...>
run() {
	local expect=$1; shift
	fixture
	local out status
	out=$(bun run "$J" "$@" 2>&1); status=$?
	local pdfs
	pdfs=$(find . -name '*.pdf' -newer a.md 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ')
	[ -z "$pdfs" ] && pdfs=$(ls -1 *.pdf 2>/dev/null | tr '\n' ' ')
	local first
	first=$(printf '%s' "$out" | grep -v '^$' | head -1 | cut -c1-66)

	printf '%-32s exit=%d  new: %-26s\n' "pdfulator $*" "$status" "${pdfs:-(none)}"
	printf '%-32s   %s\n' "" "${first:-(silent)}"

	case $expect in
		ok)   [ "$status" -eq 0 ] || { echo "   ^^ EXPECTED SUCCESS"; FAIL=1; } ;;
		fail) [ "$status" -ne 0 ] || { echo "   ^^ EXPECTED FAILURE"; FAIL=1; } ;;
	esac
	echo
}

echo "============ FILE -> (implicit) ============"
run ok   a.md
run fail nope.md
run fail real.pdf
run fail liar.pdf
run ok   empty.md

echo "============ FILE -> FILE ============"
run ok   a.md out.pdf            # dest missing
run ok   a.md real.pdf           # dest is a real PDF: replace
run ok   a.md empty.pdf          # dest zero-length: safe to claim
run fail a.md liar.pdf           # dest named .pdf but isn't: refuse
run fail a.md b.md               # dest is markdown: refuse
run fail a.md existing-out       # dest is a directory, source is a file
run fail nope.md out.pdf         # source missing
run fail nope.md real.pdf        # source missing, dest exists
run fail real.pdf out.pdf        # source is a PDF

echo "============ DIR -> (implicit) ============"
run ok   src
run ok   .
run ok   emptydir

echo "============ DIR -> DIR ============"
run ok   src existing-out        # dest dir exists
run ok   src brand-new-dir       # dest dir created
run fail src real.pdf            # dest is a file, source is a dir
run fail src a.md

echo "============ ARITY ============"
run ok
run fail a.md b.md c.md
run fail a.md b.md c.md d.md

echo "============ IDEMPOTENCE ============"
fixture
bun run "$J" a.md >/dev/null 2>&1
out=$(bun run "$J" a.md 2>&1); status=$?
printf '%-32s exit=%d   %s\n\n' "pdfulator a.md (2nd run)" "$status" "$(printf '%s' "$out" | head -1)"
[ "$status" -eq 0 ] || FAIL=1

[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
