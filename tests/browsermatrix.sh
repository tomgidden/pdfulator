#!/bin/sh
# Browser detection matrix.
#
# Detection used to live in pdfulator.js and reach the wrapper by scraping the
# printed output of --list-browsers with awk, which meant a human-readable list
# was load-bearing and untestable without a JS runtime. Now it is shell, and
# these cases can drive it against a *fabricated* set of browsers rather than
# whichever ones this machine happens to have -- so the results are the same on
# a developer's Mac, in CI, and in a bare container.
#
# The candidate table itself is not what is checked here (it is a list of
# literal paths; a test would only restate it). What is checked is the
# behaviour around it: ordering, deduplication, the managed browser's
# precedence, and that nothing is ever launched.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/paths.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-browsermatrix
FAIL=0

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

fake_browser() {  # fake_browser <path>
	mkdir -p "$(dirname -- "$1")"
	printf '#!/bin/sh\necho "a real browser would have launched" >&2\nexit 99\n' > "$1"
	chmod +x "$1"
}

fixture() {
	rm -rf "$BASE"
	mkdir -p "$BASE/home" "$BASE/sys" "$BASE/path"
	PDFULATOR_HOME="$BASE/home"
	MANAGED_BROWSER_DIR="$PDFULATOR_HOME/chromium"
	MANAGED_BROWSER="chrome-headless-shell"
}

. "$LIB/browser.sh"
fixture

# The table is platform-specific and points at real system locations, so these
# tests substitute their own. Overriding the two producers is the seam: it
# leaves ordering, dedup and the managed-browser search under test.
CANDIDATES=""
PATH_NAMES=""
browser_candidate_paths() { [ -n "$CANDIDATES" ] && printf '%s\n' "$CANDIDATES"; return 0; }
browser_path_names()      { [ -n "$PATH_NAMES" ] && printf '%s\n' "$PATH_NAMES"; return 0; }


echo "============ SET -E ============"
# The wrapper runs with `set -e`, so every one of these must survive it.
#
# This is not hypothetical. Three separate `set -e` traps in this file made
# browser_gather abort mid-listing, and the symptom was not an error: it was
# `--install` reporting "Browsers found: (none)" on a machine with two, with
# nothing on stderr to say why. The functions were all fine when tested
# without `set -e`, which is exactly why this section exists.
#
# The traps, all the same shape -- a command whose failure is *normal* left
# where the shell reads its status:
#   * `x=$(f)` where f may fail: the assignment takes f's status.
#   * `[ ... ] && cmd` as a non-final statement: a false test is a failure.
#   * a loop whose last iteration ends in a false test: the loop takes it.
#
# Run in a child shell because `set -e` cannot be scoped within one.
sete() {  # sete <description> <shell-snippet>
	if out=$(sh -c "set -e
		. '$LIB/paths.sh'; . '$LIB/browser.sh'
		$2" 2>&1); then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s (aborted under set -e)\n        %s\n' "$1" "$out"
		FAIL=1
	fi
}

# With no managed browser -- the normal case, and the one that broke.
sete "browser_gather survives set -e"     'PDFULATOR_HOME=/nonexistent; x=$(browser_gather)'
sete "browser_list survives set -e"       'PDFULATOR_HOME=/nonexistent; x=$(browser_list)'
sete "browser_list_paths survives set -e" 'PDFULATOR_HOME=/nonexistent; x=$(browser_list_paths)'
sete "browser_find_managed, guarded"      'PDFULATOR_HOME=/nonexistent; x=$(browser_find_managed) || x=""'
sete "browser_candidate_paths survives"   'x=$(browser_candidate_paths)'
# browser_best legitimately fails when there is nothing to find, so a caller
# must guard it -- but it must fail *there*, not abort the shell first.
sete "browser_best, guarded"              'x=$(browser_best) || x=""'


echo "============ EMPTY ============"
fixture
CANDIDATES=""; PATH_NAMES=""
check "nothing found lists nothing" "" "$(browser_list)"
check "nothing found has no best"   "1" "$(browser_best >/dev/null 2>&1; echo $?)"


echo "============ ORDER ============"
fixture
fake_browser "$BASE/sys/chromium"
fake_browser "$BASE/sys/google-chrome"
CANDIDATES="$BASE/sys/chromium
$BASE/sys/google-chrome"
PATH_NAMES=""
# Table order is preference order, not alphabetical or filesystem order: it
# encodes which browser a user most likely wants.
check "table order is preserved" \
      "$BASE/sys/chromium $BASE/sys/google-chrome" \
      "$(browser_list_paths | tr '\n' ' ' | sed 's/ $//')"
check "best is the first candidate" "$BASE/sys/chromium" "$(browser_best)"

# A listed path that doesn't exist is not offered. The table names locations
# for every distro and install method, so most entries are absent on any given
# machine -- filtering is the normal case, not an edge one.
fixture
fake_browser "$BASE/sys/chromium"
CANDIDATES="$BASE/sys/nonexistent
$BASE/sys/chromium"
check "absent candidates are skipped" "$BASE/sys/chromium" "$(browser_list_paths)"


echo "============ SOURCES ============"
fixture
fake_browser "$BASE/sys/chromium"
fake_browser "$BASE/path/google-chrome"
CANDIDATES="$BASE/sys/chromium"
PATH_NAMES="google-chrome"
PATH="$BASE/path:$PATH" \
	check "PATH entries are labelled as such" \
	      "$BASE/sys/chromium	system $BASE/path/google-chrome	on PATH" \
	      "$(PATH="$BASE/path:$PATH" browser_list | tr '\n' ' ' | sed 's/ $//')"

# $PATH is searched last, and deliberately: anything named `chromium` anywhere
# on the path matches, so it is the least predictable source.
fixture
fake_browser "$BASE/sys/chromium"
fake_browser "$BASE/path/chromium-browser"
CANDIDATES="$BASE/sys/chromium"
PATH_NAMES="chromium-browser"
check "known locations beat PATH" "$BASE/sys/chromium" \
      "$(PATH="$BASE/path:$PATH" browser_best)"


echo "============ DEDUPLICATION ============"
# The same binary reachable two ways -- listed in the table *and* on $PATH --
# is one browser, and must be offered once. Presenting it twice would make a
# numbered menu misleading, since two entries would do the same thing.
fixture
fake_browser "$BASE/path/chromium"
CANDIDATES="$BASE/path/chromium"
PATH_NAMES="chromium"
check "one binary, two routes, one entry" "1" \
      "$(PATH="$BASE/path:$PATH" browser_list | grep -c .)"
check "kept under the more trustworthy source" "$BASE/path/chromium	system" \
      "$(PATH="$BASE/path:$PATH" browser_list)"


echo "============ MANAGED ============"
# The browser pdfulator installed for itself wins over everything: the user
# asked for it explicitly, and it is the one build known to work.
fixture
mkdir -p "$MANAGED_BROWSER_DIR/$MANAGED_BROWSER/mac-1000/chrome-headless-shell-mac"
fake_browser "$MANAGED_BROWSER_DIR/$MANAGED_BROWSER/mac-1000/chrome-headless-shell-mac/chrome-headless-shell"
fake_browser "$BASE/sys/chromium"
CANDIDATES="$BASE/sys/chromium"
PATH_NAMES=""
check "managed browser is found" \
      "$MANAGED_BROWSER_DIR/$MANAGED_BROWSER/mac-1000/chrome-headless-shell-mac/chrome-headless-shell" \
      "$(browser_find_managed)"
check "managed browser comes first" \
      "$MANAGED_BROWSER_DIR/$MANAGED_BROWSER/mac-1000/chrome-headless-shell-mac/chrome-headless-shell" \
      "$(browser_best)"
check "managed browser is labelled" "installed by pdfulator" \
      "$(browser_list | head -1 | cut -f2)"

# Newest build first, so an upgrade takes effect without a manual clean.
fixture
for b in mac-1000 mac-1200 mac-1100; do
	fake_browser "$MANAGED_BROWSER_DIR/$MANAGED_BROWSER/$b/inner/chrome-headless-shell"
done
CANDIDATES=""; PATH_NAMES=""
check "newest managed build wins" \
      "$MANAGED_BROWSER_DIR/$MANAGED_BROWSER/mac-1200/inner/chrome-headless-shell" \
      "$(browser_find_managed)"

fixture
CANDIDATES=""; PATH_NAMES=""
check "no managed browser is not an error" "1" \
      "$(browser_find_managed >/dev/null 2>&1; echo $?)"


echo "============ CONSENT ============"
# The governing rule: searching must never launch anything. The fakes exit 99
# and print to stderr if run, so a listing that stays silent proves it.
fixture
fake_browser "$BASE/sys/chromium"
CANDIDATES="$BASE/sys/chromium"
PATH_NAMES=""
check "detection launches nothing" "" "$(browser_list 2>&1 >/dev/null)"


echo "============ USABILITY ============"
fixture
fake_browser "$BASE/path/chromium"
check "an executable path is usable"  "0" "$(browser_is_usable "$BASE/path/chromium"; echo $?)"
check "a command name is usable"      "0" "$(PATH="$BASE/path:$PATH" browser_is_usable chromium; echo $?)"
check "a missing path is not"         "1" "$(browser_is_usable "$BASE/path/nope"; echo $?)"
check "an empty argument is not"      "1" "$(browser_is_usable ""; echo $?)"
# A directory is not a browser, however plausibly named -- on macOS the thing a
# user is most likely to reach for is `/Applications/Google Chrome.app`, which
# is a bundle, not the binary several levels inside it.
check "a directory is not a browser"  "1" "$(browser_is_usable "$BASE/sys"; echo $?)"


echo "============ BUNDLES ============"
# Naming the .app is the natural thing to type on macOS, so it is resolved to
# the binary inside rather than refused.
fixture
fake_browser "$BASE/sys/Google Chrome.app/Contents/MacOS/Google Chrome"
check "bundle resolves to its binary" \
      "$BASE/sys/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "$(browser_resolve_bundle "$BASE/sys/Google Chrome.app")"
check "a trailing slash is the same bundle" \
      "$BASE/sys/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "$(browser_resolve_bundle "$BASE/sys/Google Chrome.app/")"

# The binary is not always named for the bundle; a single executable in
# Contents/MacOS is unambiguous, so it is taken.
fixture
fake_browser "$BASE/sys/Brave.app/Contents/MacOS/Brave Browser"
check "differently-named binary is found" \
      "$BASE/sys/Brave.app/Contents/MacOS/Brave Browser" \
      "$(browser_resolve_bundle "$BASE/sys/Brave.app")"

# Two executables and no name match is a guess, and guessing which binary in
# someone's browser to launch is not this tool's business.
fixture
fake_browser "$BASE/sys/Odd.app/Contents/MacOS/one"
fake_browser "$BASE/sys/Odd.app/Contents/MacOS/two"
check "ambiguous bundle is refused" "1" \
      "$(browser_resolve_bundle "$BASE/sys/Odd.app" >/dev/null 2>&1; echo $?)"

fixture
mkdir -p "$BASE/sys/Empty.app/Contents/MacOS"
check "empty bundle is refused" "1" \
      "$(browser_resolve_bundle "$BASE/sys/Empty.app" >/dev/null 2>&1; echo $?)"
check "a non-bundle is not a bundle" "1" \
      "$(browser_resolve_bundle "$BASE/sys" >/dev/null 2>&1; echo $?)"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
