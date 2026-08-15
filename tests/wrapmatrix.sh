#!/bin/bash
# Wrapper argument-parsing matrix. Exercises pdfulator.sh (not pdfulator.js):
# wrapper-only flags in any position, value-taking flags, and pass-through.
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${TMPDIR:-/tmp}/pdfulator-wrapmatrix
W=$S/wrap
FAIL=0

fixture() {
	rm -rf "$W"; mkdir -p "$W/home" "$W/bin" "$W/work"
	tar xzf $REPO/pdfulator.tar.gz -C "$W/home"
	cp $REPO/pdfulator.sh "$W/bin/pdfulator"
	chmod +x "$W/bin/pdfulator"
	ln -s $REPO/node_modules "$W/home/node_modules" 2>/dev/null
	printf '# T\n\nBody.\n' > "$W/work/t.md"
	mkdir -p "$W/theme-b" && : > "$W/theme-b/print.css"
	cd "$W/work" || exit 1
}

# run "<expect>" "<must-appear-in-output>" <args...>
run() {
	local expect=$1 want=$2; shift 2
	fixture
	local out status
	out=$(PDFULATOR_HOME="$W/home" PDFULATOR_BIN="$W/bin" \
	      CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
	      "$W/bin/pdfulator" "$@" 2>&1); status=$?
	local stray
	stray=$(ls -A "$W/work" | grep -v '^t\.md$' | grep -v '\.pdf$' | tr '\n' ' ')

	printf '%-40s exit=%d\n' "pdfulator $*" "$status"
	[ -n "$stray" ] && { printf '%-40s   STRAY FILES: %s\n' "" "$stray"; FAIL=1; }

	case $expect in
		ok)   [ "$status" -eq 0 ] || { echo "   ^^ EXPECTED SUCCESS"; FAIL=1; } ;;
		fail) [ "$status" -ne 0 ] || { echo "   ^^ EXPECTED FAILURE"; FAIL=1; } ;;
	esac
	if [ -n "$want" ]; then
		printf '%s' "$out" | grep -qi -- "$want" || {
			printf '   ^^ expected output matching: %s\n      got: %s\n' \
			  "$want" "$(printf '%s' "$out" | head -1)"; FAIL=1; }
	fi
	echo
}

echo "===== wrapper flags in NON-LEADING position ====="
run fail "not.*installed\|Uninstalling"  t.md --uninstall
run ok   "browser\|bun\|Ready"           t.md --setup-status

echo "===== value-taking flags: value must not be eaten ====="
run ok   ""                              --theme "$W/theme-b" t.md
run fail "needs a name or path"          t.md --theme
run fail "needs auto, find, install"     t.md --browser

echo "===== a theme literally named like a wrapper flag ====="
# "-b" must reach pdfulator.js as the theme name -- not be eaten by the
# wrapper's own -b. It then fails as a missing theme, which is the point:
# the error names the theme, proving the value was passed through.
run fail 'no theme named "-b"'           --theme -b t.md

echo "===== combinations refused ====="
run fail "can't be combined"             --uninstall --setup-status

echo "===== normal pass-through still works ====="
run ok   ""                              -v t.md out.pdf

[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
