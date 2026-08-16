#!/bin/sh
# Argument matrix, end to end through the null engine.
#
# Same cases and same expectations as the v2 tests/argmatrix.sh, but driving
# the whole path -- job planning, then dispatch to an engine that actually
# writes files -- rather than either the planner alone or a real renderer.
#
# The null engine is what makes this possible: no browser, no JS runtime, no
# Docker, milliseconds per case. So a failure here is unambiguously the
# framework's, never Vivliostyle's or Chromium's. It also lets the matrix check
# things a planner-only test cannot: that the PDFs were really written, where
# they were meant to go, from the source they were meant to come from.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
ENGINE=$(cd "$(dirname "$0")/../engines/null" && pwd)/convert
. "$LIB/paths.sh"
. "$LIB/jobs.sh"

# Normalised: TMPDIR ends in a slash on macOS, and a doubled slash makes
# comparisons against resolved paths fail for no interesting reason.
BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-planmatrix
FAIL=0
THEME=/test/theme

fixture() {
	rm -rf "$BASE"; mkdir -p "$BASE"; cd "$BASE" || exit 1
	for n in a b c; do printf '# Doc %s\n\nBody of %s.\n' "$n" "$n" > "$n.md"; done
	printf '%%PDF-1.4\n%%real enough\n'           > real.pdf
	printf '# Actually markdown\n\nDespite it.\n' > liar.pdf
	mkdir -p src && for n in x y; do printf '# %s\n\nIn src.\n' "$n" > "src/$n.md"; done
	mkdir -p existing-out
	: > empty.md
	: > empty.pdf
	mkdir -p emptydir
}

ERRMSG=""
jobs_error() { ERRMSG=$(printf '%s' "$1" | head -1); }

# Plan, then run every planned job through the engine -- which is what the
# wrapper will do once lib/engines.sh exists.
run() {
	expect=$1; shift
	fixture
	ERRMSG=""
	jobs_plan "$@"; status=$?

	made=""
	if [ "$status" -eq 0 ]; then
		jobs_each | while IFS='	' read -r i o; do
			[ -n "$i" ] || continue
			"$ENGINE" "$i" "$o" "$THEME" || echo "ENGINE-FAILED $i" >&2
		done
		# List only PDFs this run actually produced -- identified by the
		# engine's own stamp, so pre-existing fixture PDFs (real.pdf, liar.pdf,
		# empty.pdf) can't be mistaken for output. `find -newer`, which the v2
		# harness used, could not tell the difference.
		made=$(find . -name '*.pdf' 2>/dev/null | while read -r p; do
			grep -q '^%%pdfulator-engine: null' "$p" 2>/dev/null &&
				printf '%s\n' "${p#./}"
		done | sort | tr '\n' ' ')
	fi

	printf '%-28s exit=%d  %s\n' "pdfulator $*" "$status" "${made:-${ERRMSG:-(none)}}"
	case $expect in
		ok)   [ "$status" -eq 0 ] || { echo "   ^^ EXPECTED SUCCESS"; FAIL=1; } ;;
		fail) [ "$status" -ne 0 ] || { echo "   ^^ EXPECTED FAILURE"; FAIL=1; } ;;
	esac
}

echo "============ FILE -> (implicit) ============"
run ok   a.md
run fail nope.md
run fail real.pdf
run fail liar.pdf
run ok   empty.md

echo "============ FILE -> FILE ============"
run ok   a.md out.pdf
run ok   a.md real.pdf
run ok   a.md empty.pdf
run fail a.md liar.pdf
run fail a.md b.md
run fail a.md existing-out
run fail nope.md out.pdf
run fail nope.md real.pdf
run fail real.pdf out.pdf

echo "============ DIR -> (implicit) ============"
run ok   src
run ok   .
run ok   emptydir

echo "============ DIR -> DIR ============"
run ok   src existing-out
run ok   src brand-new-dir
run fail src real.pdf
run fail src a.md

echo "============ ARITY ============"
run ok
run fail a.md b.md c.md
run fail a.md b.md c.md d.md

# --- Assertions the null engine's diagnostics make possible -------------------
#
# Planning can look right while dispatch quietly sends the wrong document, or
# drops the theme. These check the engine received what the wrapper resolved.

echo "============ CONTRACT ============"

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

field() { sed -n "s/^%%pdfulator-$2: //p" "$1" | head -1; }

fixture
jobs_plan a.md out.pdf
jobs_each | while IFS='	' read -r i o; do "$ENGINE" "$i" "$o" "$THEME"; done
check "output is a real PDF"        "%PDF"       "$(dd if=out.pdf bs=1 count=4 2>/dev/null)"
check "engine saw the right source" "Doc a"      "$(field out.pdf title)"
check "engine got the theme"        "$THEME"     "$(field out.pdf theme)"
check "engine wrote where told"     "$BASE/out.pdf" "$(field out.pdf output)"

# Each file in a directory batch must get its own content, not the first one's.
fixture
jobs_plan src outdir
jobs_each | while IFS='	' read -r i o; do "$ENGINE" "$i" "$o" "$THEME"; done
check "batch keeps documents apart (x)" "x" "$(field outdir/x.pdf title)"
check "batch keeps documents apart (y)" "y" "$(field outdir/y.pdf title)"

# An engine that fails must not leave a plausible-looking PDF behind.
fixture
"$ENGINE" nope.md ghost.pdf "$THEME" 2>/dev/null
check "no output when the engine fails" "absent" \
      "$([ -e ghost.pdf ] && echo present || echo absent)"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
