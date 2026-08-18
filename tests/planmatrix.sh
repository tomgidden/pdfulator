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
# Resolved before anything else: fixture() cd's into the fixture directory, so
# a path relative to $0 stops working the moment the first case runs.
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB=$REPO/lib
ENGINE=$REPO/engines/null/convert
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

# Defined here rather than beside the CONTRACT section that first used it: sh
# resolves a function only once it has been read, and the STREAMS cases below
# call this earlier in the file.
check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}


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

echo "============ STREAMS ============"
# "-" means a stream, and *which* stream depends on where it appears: as the
# input it is stdin, as the output it is stdout. These go through the wrapper
# rather than jobs_plan, because the routing is the wrapper's -- planning has
# nothing to say about a stream, which is the point.
#
# The case that matters is `doc.md -`, a file to stdout. An earlier wrapper
# searched the whole argument list for a bare "-" and treated any hit as
# stdin-to-stdout, so this read stdin and ignored doc.md: it hung on a terminal
# and reported "empty input on stdin" in a pipeline, for the documented way to
# pipe one document. Found by running the container engine, which is why the
# fix is pinned here rather than only there.
W=$REPO/pdfulator.sh
W_DIR=$REPO
SBASE=$BASE/streams

stream_run() {  # stream_run <description> <expected-input-stamp> <args...>
	_sr_desc=$1; _sr_want=$2; shift 2
	rm -rf "$SBASE"; mkdir -p "$SBASE/home"
	printf '# Streamed\n\nBody.\n' > "$SBASE/doc.md"
	mkdir -p "$SBASE/adir"; printf '# In dir\n' > "$SBASE/adir/x.md"

	# The null engine stamps what it was given into the PDF, so the assertion
	# is on what the engine actually received rather than on exit status --
	# which was 0 throughout the bug.
	_sr_got=$( cd "$SBASE" && \
		PDFULATOR_DIR="$W_DIR" PDFULATOR_HOME="$SBASE/home" \
		sh "$W" --engine null "$@" 2>/dev/null </dev/null |
		sed -n 's/^%%pdfulator-input: //p' | head -1 )
	check "$_sr_desc" "$_sr_want" "$_sr_got"
}

# A file to stdout reads the file, not stdin.
stream_run "file to stdout reads the file" "doc.md" doc.md -

# stdin to stdout, the bare-pipe case.
rm -rf "$SBASE"; mkdir -p "$SBASE/home"
printf '# Piped\n' > "$SBASE/doc.md"
STDIN_GOT=$( cd "$SBASE" && printf '# Piped in\n' |
	PDFULATOR_DIR="$W_DIR" PDFULATOR_HOME="$SBASE/home" \
	sh "$W" --engine null - 2>/dev/null |
	sed -n 's/^%%pdfulator-input: //p' | head -1 )
check "stdin to stdout reads stdin" "<stdin>" "$STDIN_GOT"

# stdin to a named file: the output must be that file, not stdout. The old
# code forced both ends to "-" as soon as it saw a dash anywhere, so the PDF
# went to the terminal and the named file was never written.
rm -rf "$SBASE"; mkdir -p "$SBASE/home"
( cd "$SBASE" && printf '# To a file\n' |
	PDFULATOR_DIR="$W_DIR" PDFULATOR_HOME="$SBASE/home" \
	sh "$W" --engine null - out.pdf >/dev/null 2>&1 )
check "stdin to a file writes that file" "yes" \
      "$([ -f "$SBASE/out.pdf" ] && echo yes || echo no)"
check "and the engine was told so" "out.pdf" \
      "$(sed -n 's/^%%pdfulator-output: //p' "$SBASE/out.pdf" 2>/dev/null | head -1)"

# A directory cannot go to one stream. Refused rather than silently converting
# only the first document.
rm -rf "$SBASE"; mkdir -p "$SBASE/home/x"
mkdir -p "$SBASE/adir"; printf '# d\n' > "$SBASE/adir/x.md"
( cd "$SBASE" && PDFULATOR_DIR="$W_DIR" PDFULATOR_HOME="$SBASE/home" \
	sh "$W" --engine null adir - >/dev/null 2>&1 </dev/null )
check "a directory to stdout is refused" "1" "$?"


echo "============ ARITY ============"
run ok
run fail a.md b.md c.md
run fail a.md b.md c.md d.md

# --- Assertions the null engine's diagnostics make possible -------------------
#
# Planning can look right while dispatch quietly sends the wrong document, or
# drops the theme. These check the engine received what the wrapper resolved.

echo "============ CONTRACT ============"

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
