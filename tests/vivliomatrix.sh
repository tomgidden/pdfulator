#!/bin/sh
# The vivlio engine against the engine contract.
#
# tests/planmatrix.sh proves the framework using the null engine, which has no
# dependencies; this proves the real engine honours the same contract. The two
# are deliberately separate: this one needs a browser and a JS runtime, takes
# seconds per case rather than milliseconds, and a failure here means the
# engine, not the framework.
#
# What it does not test is how the PDF *looks*. That needs an eye, or a
# reference rendering, and neither belongs in a contract test -- what belongs
# is that the four input/output combinations work, that the wrapper's three
# arguments are honoured, and that failures fail cleanly.
#
#   CHROME_PATH=... PDFULATOR_RUNTIME=... sh tests/vivliomatrix.sh
#
# Both are discovered when unset, so it usually runs bare.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/lib"
ENGINE="$ROOT/engines/vivlio/convert"
THEME="$ROOT/theme"

. "$LIB/paths.sh"
. "$LIB/browser.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-vivliomatrix
FAIL=0

# The wrapper's job, done by hand: settle the browser and runtime before the
# engine runs. The engine never searches for either -- that is the contract.
: "${CHROME_PATH:=$(browser_best 2>/dev/null)}"
: "${PDFULATOR_RUNTIME:=$(command -v bun || command -v node || command -v deno)}"
export CHROME_PATH PDFULATOR_RUNTIME

if [ -z "$CHROME_PATH" ] || [ -z "$PDFULATOR_RUNTIME" ]; then
	echo "SKIP: vivlio needs a browser and a JS runtime."
	echo "  browser: ${CHROME_PATH:-(none found)}"
	echo "  runtime: ${PDFULATOR_RUNTIME:-(none found)}"
	# Not a failure: a machine without either can still run the rest of the
	# suite, and pretending otherwise would make `make test` unusable there.
	exit 0
fi

if [ ! -d "$ROOT/engines/vivlio/node_modules" ]; then
	echo "SKIP: engines/vivlio/node_modules is missing (run: cd engines/vivlio && bun install)"
	exit 0
fi

echo "browser: $CHROME_PATH"
echo "runtime: $PDFULATOR_RUNTIME"
echo

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

is_pdf() { [ -s "$1" ] && [ "$(dd if="$1" bs=1 count=5 2>/dev/null)" = "%PDF-" ]; }

fixture() {
	rm -rf "$BASE"; mkdir -p "$BASE"; cd "$BASE" || exit 1
	printf -- '---\ntitle: Contract\n---\n\n# Heading\n\nA paragraph.\n' > in.md
	printf -- '# Other\n\nDifferent words entirely.\n' > other.md
}


echo "============ FILE -> FILE ============"
fixture
"$ENGINE" in.md out.pdf "$THEME" >/dev/null 2>&1
check "wrote a PDF where told" "yes" "$(is_pdf out.pdf && echo yes || echo no)"

echo "============ STDIN -> STDOUT ============"
fixture
"$ENGINE" - - "$THEME" < in.md > piped.pdf 2>/dev/null
check "stdin to stdout is a PDF" "yes" "$(is_pdf piped.pdf && echo yes || echo no)"

# The same document by two routes must render the same. Only the embedded
# timestamp may differ -- if more does, one path is doing something the other
# isn't, which is how processFile and processStdin drifted apart in v2.
fixture
"$ENGINE" in.md a.pdf "$THEME" >/dev/null 2>&1
"$ENGINE" - - "$THEME" < in.md > b.pdf 2>/dev/null
check "file and stdin agree (size)" "$(wc -c < a.pdf)" "$(wc -c < b.pdf)"

echo "============ MIXED ============"
fixture
"$ENGINE" in.md - "$THEME" > tostdout.pdf 2>/dev/null
check "file to stdout" "yes" "$(is_pdf tostdout.pdf && echo yes || echo no)"
fixture
"$ENGINE" - fromstdin.pdf "$THEME" < in.md >/dev/null 2>&1
check "stdin to file" "yes" "$(is_pdf fromstdin.pdf && echo yes || echo no)"

echo "============ CONTENT ============"
# Different input must produce a different document. A pipeline that renders
# the template but drops the body would pass every check above.
fixture
"$ENGINE" in.md one.pdf "$THEME" >/dev/null 2>&1
"$ENGINE" other.md two.pdf "$THEME" >/dev/null 2>&1
check "different input, different output" "differs" \
      "$(cmp -s one.pdf two.pdf && echo same || echo differs)"

echo "============ OUTPUT DIRECTORY ============"
# The wrapper plans `dir/ outdir/` jobs into a directory that may not exist
# yet, so the engine creates it rather than failing.
fixture
"$ENGINE" in.md sub/dir/out.pdf "$THEME" >/dev/null 2>&1
check "creates missing output directory" "yes" \
      "$(is_pdf sub/dir/out.pdf && echo yes || echo no)"

echo "============ FAILURE ============"
# A failing conversion must not leave something that looks like a PDF: the
# next run would see a plausible file and the user would send it.
fixture
"$ENGINE" nosuchfile.md ghost.pdf "$THEME" >/dev/null 2>&1
check "no output when input is missing" "absent" \
      "$([ -e ghost.pdf ] && echo present || echo absent)"
check "and a non-zero exit" "yes" \
      "$("$ENGINE" nosuchfile.md g2.pdf "$THEME" >/dev/null 2>&1 || echo yes)"

# An empty *file* renders blank rather than failing: it is a document someone
# has started and not yet written, and `pdfulator dir/` over a directory
# containing one should not abort the whole batch. Empty *stdin* is the
# opposite -- it means the pipe produced nothing, which a blank PDF would hide.
fixture
: > empty.md
"$ENGINE" empty.md empty-out.pdf "$THEME" >/dev/null 2>&1
check "an empty file renders blank" "yes" \
      "$(is_pdf empty-out.pdf && echo yes || echo no)"

fixture
check "empty stdin is refused" "yes" \
      "$("$ENGINE" - - "$THEME" < /dev/null >/dev/null 2>&1 || echo yes)"

fixture
"$ENGINE" in.md out.pdf "$BASE/no-such-theme" >/dev/null 2>&1
check "missing theme is refused" "absent" \
      "$([ -e out.pdf ] && echo present || echo absent)"

# The engine is told which browser to use and never goes looking. Without one
# it must say so rather than searching -- the consent rule, from the engine's
# side.
fixture
check "no browser is an error, not a search" "yes" \
      "$(env -u CHROME_PATH "$ENGINE" in.md nb.pdf "$THEME" >/dev/null 2>&1 || echo yes)"

# Wrong arity is a bug in the caller, not a user mistake, and exits 2 to say so.
fixture
check "wrong arity exits 2" "2" \
      "$("$ENGINE" in.md out.pdf >/dev/null 2>&1; echo $?)"


echo "============ CROSS-DEVICE OUTPUT ============"
# The engine renders into $TMPDIR and moves the result into place, and
# rename(2) cannot cross filesystems. When $TMPDIR and the output are on
# different devices the move fails with EXDEV *after* a perfect render, which
# reads as "conversion failed" for a conversion that succeeded.
#
# In a container this is the normal case rather than bad luck: the output
# directory is a bind mount, so every write to it crosses a device boundary.
# It was found by running the image (see tests/dockermatrix.sh for that side)
# and is fixed by falling back to copy-then-unlink.
#
# Testing it needs two real filesystems, which not every machine has to hand.
# Where one can be had cheaply -- Linux's /dev/shm is a tmpfs and separate
# from anything on disk -- use it; otherwise say so rather than passing
# silently, since a skipped case that looks like a pass is worse than no case.
fixture
OTHER_FS=""
for _d in /dev/shm /run/shm; do
	if [ -d "$_d" ] && [ -w "$_d" ]; then OTHER_FS=$_d; break; fi
done

if [ -n "$OTHER_FS" ]; then
	XDEV=$(mktemp -d "$OTHER_FS/pdfulator-xdev.XXXXXX")
	TMPDIR="$XDEV" "$ENGINE" in.md xdev.pdf "$THEME" >/dev/null 2>&1
	check "output survives a cross-device move" "yes" \
	      "$(is_pdf xdev.pdf && echo yes || echo no)"
	rm -rf "$XDEV"
else
	printf 'skip  cross-device move (no second filesystem here)\n'
fi

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
