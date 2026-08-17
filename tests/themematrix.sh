#!/bin/sh
# Theme resolution matrix.
#
# The engine contract hands over a theme *directory*, so every way a user can
# name one has to collapse to a path before dispatch. These cases are the ones
# resolveTheme() in the v2 pdfulator.js was written to handle, checked against
# the shell port that replaced it.
#
# The interesting cases are the refusals. A named theme that isn't found must
# be an error rather than a silent fall back to the built-in one, per commit
# 36236a6 -- a typo that renders in the default style produces a plausible PDF
# that only looks wrong to the eye, which is the worst kind of failure to ship.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/paths.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-themematrix
FAIL=0

# A whole world of theme roots: a working directory, an installed home, and an
# unpacked distribution, so precedence between the three is observable.
fixture() {
	rm -rf "$BASE"
	mkdir -p "$BASE/cwd/themes/local" \
	         "$BASE/home/themes/installed" \
	         "$BASE/dist/themes/shipped" \
	         "$BASE/dist/theme" \
	         "$BASE/elsewhere/handwritten"

	# The same name in all three roots, to prove which one wins.
	mkdir -p "$BASE/cwd/themes/shared" \
	         "$BASE/home/themes/shared" \
	         "$BASE/dist/themes/shared"

	PDFULATOR_HOME="$BASE/home"
	PDFULATOR_DIR="$BASE/dist"
	BUILTIN_THEME="$PDFULATOR_DIR/theme"
	cd "$BASE/cwd" || exit 1
}

fixture
. "$LIB/theme.sh"

ERRMSG=""
theme_error() { ERRMSG=$(printf '%s' "$1" | head -1); }

# Resolution writes its "Looked in:" list straight to stderr; the tests care
# about the outcome, not the list, so it is dropped here.
run() {  # run <expect: ok|fail> <expected-result-or-blank> [arg]
	expect=$1; want=$2; shift 2
	fixture
	ERRMSG=""
	got=$(theme_resolve "$@" 2>/dev/null); status=$?

	printf '%-34s exit=%d  %s\n' "--theme ${1:-(none)}" "$status" \
	       "${got:-${ERRMSG:-(none)}}"

	case $expect in
		ok)
			if [ "$status" -ne 0 ]; then
				echo "   ^^ EXPECTED SUCCESS"; FAIL=1
			elif [ -n "$want" ] && [ "$got" != "$want" ]; then
				printf '   ^^ EXPECTED %s\n' "$want"; FAIL=1
			fi
			;;
		fail)
			[ "$status" -ne 0 ] || { echo "   ^^ EXPECTED FAILURE"; FAIL=1; }
			;;
	esac
}

echo "============ DEFAULT ============"
run ok "$BASE/dist/theme"

echo "============ NAMES ============"
run ok   "$BASE/cwd/themes/local"      local
run ok   "$BASE/home/themes/installed" installed
run ok   "$BASE/dist/themes/shipped"   shipped
run fail ""                            nosuchtheme

echo "============ PRECEDENCE ============"
# cwd beats the installed home, which beats the distribution.
run ok "$BASE/cwd/themes/shared" shared

echo "============ PATHS ============"
run ok   "$BASE/elsewhere/handwritten" "$BASE/elsewhere/handwritten"
run ok   "$BASE/cwd/themes/local"      ./themes/local
run ok   "$BASE/elsewhere/handwritten" ../elsewhere/handwritten
run fail ""                            /nonexistent/theme
run fail ""                            ./nope

# A bare relative name with a slash is a *name*, not a path: it is searched for
# under themes/, so themes/local resolves only if themes/themes/local exists.
# The distinction matters because the two readings differ in what they find.
run fail "" themes/local

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
