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

# The wrapper, not the engine. These cases are the CLI contract, and the CLI is
# the wrapper's: it plans the jobs and an engine only converts. Running the
# engine directly, as this did when there was one hardcoded pipeline, would now
# test something no user invokes.
#
# tests/planmatrix.sh covers the same 24 cases against the planner alone in
# about a second. This is the slow confirmation that the same contract holds
# with a real renderer on the end of it.
P=$REPO/pdfulator.sh

# Detected rather than assumed: the hardcoded /Applications path this used to
# carry is wrong on any machine with a per-user Chrome install, and failed as a
# conversion that "should have worked" rather than as a missing browser.
. "$REPO/lib/paths.sh"
. "$REPO/lib/browser.sh"
export CHROME_PATH="${CHROME_PATH:-$(browser_best 2>/dev/null)}"
if [ -z "$CHROME_PATH" ]; then
	echo "SKIP: no Chromium-family browser found; argmatrix needs one."
	exit 0
fi

# A FRESH DIRECTORY PER CASE, never one path reused.
#
# This test used to reuse a single $BASE, deleting and recreating it in
# fixture(). On macOS that makes roughly half the docker cases fail with
#
#   pandoc-pagedjs: no such input: /in/a.md
#
# The mount is correct and the file is there on the host; Docker Desktop's
# file-sharing layer is still serving the inode the path had BEFORE the
# `rm -rf`, so /in arrives empty. It clears on its own after a moment, which is
# what made this intermittent and made the failures look like a wrapper bug in
# whichever case happened to land on a stale mount.
#
# Demonstrated directly, without pdfulator in the picture:
#
#   rm -rf $D; mkdir $D; touch $D/a.md
#   docker run --rm -v $D:/in:ro alpine ls /in    # -> a.md
#   rm -rf $D; mkdir $D; touch $D/a.md
#   docker run --rm -v $D:/in:ro alpine ls /in    # -> (empty)
#
# A path that has never been deleted-and-recreated always mounts correctly, so
# each case gets its own. $BASE_ROOT is removed once, at exit, after every
# container has finished with it.
BASE_ROOT=${TMPDIR:-/tmp}/pdfulator-argmatrix.$$
CASE=0
FAIL=0
trap 'rm -rf "$BASE_ROOT"' EXIT INT TERM

fixture() {
	CASE=$((CASE + 1))
	BASE=$BASE_ROOT/case-$CASE
	mkdir -p "$BASE"; cd "$BASE" || exit 1
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
	out=$(PDFULATOR_DIR="$REPO" "$P" "$@" 2>&1); status=$?
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
PDFULATOR_DIR="$REPO" "$P" a.md >/dev/null 2>&1
out=$(PDFULATOR_DIR="$REPO" "$P" a.md 2>&1); status=$?
printf '%-32s exit=%d   %s\n\n' "pdfulator a.md (2nd run)" "$status" "$(printf '%s' "$out" | head -1)"
[ "$status" -eq 0 ] || FAIL=1

[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
