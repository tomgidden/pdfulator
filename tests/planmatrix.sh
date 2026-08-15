#!/bin/sh
# Planner-only mirror of tests/argmatrix.sh: same cases, same expectations,
# but exercising lib/jobs.sh alone -- no engine, no browser, no PDF.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/paths.sh"
. "$LIB/jobs.sh"

BASE=${TMPDIR:-/tmp}/pdfulator-planmatrix
FAIL=0

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

run() {
	expect=$1; shift
	fixture
	ERRMSG=""
	jobs_plan "$@"; status=$?
	n=$(jobs_count)
	desc=$(jobs_each | sed "s|$BASE/||g" | awk -F'\t' '{printf "%s>%s ", $1, $2}')

	printf '%-28s exit=%d n=%-2s %s\n' "pdfulator $*" "$status" "$n" "${desc:-$ERRMSG}"
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

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
