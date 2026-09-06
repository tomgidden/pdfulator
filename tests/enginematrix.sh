#!/bin/sh
# Engine discovery, selection and pinning.
#
# Built against fabricated engines rather than the real ones, so the cases can
# cover combinations that do not exist yet -- a deprecated engine, a docker
# engine, an engine with no runtime -- and so they stay fixed while the real
# engines change. Selection is what is under test, not any renderer.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/conf.sh"
. "$LIB/paths.sh"

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-enginematrix
FAIL=0

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

# A minimal engine: whatever keys are given, plus a convert that records that
# it ran and with what.
make_engine() {  # make_engine <id> [key=value ...]
	_me_id=$1; shift
	mkdir -p "$ENGINES_DIR/$_me_id"
	{
		printf 'id=%s\n' "$_me_id"
		printf 'description=The %s engine\n' "$_me_id"
		for _me_kv in "$@"; do printf '%s\n' "$_me_kv"; done
	} > "$ENGINES_DIR/$_me_id/engine.conf"

	cat > "$ENGINES_DIR/$_me_id/convert" <<EOF
#!/bin/sh
printf '%s|%s|%s|%s|%s|%s\n' "$_me_id" "\$1" "\$2" "\$3" \
	"\${CHROME_PATH:-no-chrome}" "\${PDFULATOR_DEFAULTS:-no-defaults}" \
	>> "$BASE/ran"
EOF
	chmod +x "$ENGINES_DIR/$_me_id/convert"
}

fixture() {
	rm -rf "$BASE"
	mkdir -p "$BASE/home" "$BASE/dist/engines" "$BASE/dist/defaults"
	PDFULATOR_HOME="$BASE/home"
	PDFULATOR_DIR="$BASE/dist"
	ENGINES_DIR="$BASE/dist/engines"
	ENGINE_CONF="$PDFULATOR_HOME/.engine"
	: > "$BASE/ran"
}

fixture
. "$LIB/engines.sh"
# Sourcing fixed these from the environment at the time; the fixture resets
# them per case, so re-point them here as the wrapper would.
ENGINES_DIR="$BASE/dist/engines"
ENGINE_CONF="$BASE/home/.engine"

ERRMSG=""
engines_error() { ERRMSG=$(printf '%s' "$1" | head -1); }

setup() {  # setup — a standard cast of engines
	fixture
	ENGINES_DIR="$BASE/dist/engines"
	ENGINE_CONF="$BASE/home/.engine"
	make_engine vivlio needs_runtime=js  needs_browser=yes needs_docker=no \
	            deprecated=no internal=no \
	            parser=markdown-it styler=vivliostyle renderer=chromium
	make_engine pandoc-xslt needs_runtime=none needs_browser=no needs_docker=yes \
	            deprecated=yes internal=no image=tomgidden/pdfulator:pandoc-xslt \
	            parser=pandoc styler=xslt renderer=fop
	make_engine null needs_runtime=none needs_browser=no needs_docker=no \
	            deprecated=no internal=yes
	ERRMSG=""
}


echo "============ SET -E ============"
# The wrapper runs with `set -e`. A `[ ... ] && ...` whose test is false is a
# failing command, and as a non-final statement that aborts the caller with no
# message -- which is how browser_gather came to report no browsers on a
# machine with two. Same shapes exist here, so they get the same guard.
sete() {  # sete <description> <shell-snippet>
	if out=$(sh -c "set -e
		PDFULATOR_DIR='$BASE/dist'; PDFULATOR_HOME='$BASE/home'
		. '$LIB/conf.sh'; . '$LIB/paths.sh'; . '$LIB/engines.sh'
		ENGINES_DIR='$BASE/dist/engines'; ENGINE_CONF='$BASE/home/.engine'
		$2" 2>&1); then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s (aborted under set -e)\n        %s\n' "$1" "$out"
		FAIL=1
	fi
}

setup
sete "engines_list survives set -e"      'x=$(engines_list)'
sete "engine_get survives set -e"        'x=$(engine_get vivlio parser)'
sete "engine_get on a missing key"       'x=$(engine_get vivlio nosuchkey) || true'
sete "engine_resolve survives set -e"    'x=$(engine_resolve)'
sete "engines_describe survives set -e"  'x=$(engines_describe)'
sete "engine_pin of an internal engine"  'engine_pin null'
# The predicates are *meant* to return non-zero; a caller must use them in a
# conditional, and they must not abort before it can.
sete "needs_* predicates, in a test"     'if engine_needs_docker vivlio; then :; fi'
sete "engine_is_internal, in a test"     'if engine_is_internal vivlio; then :; fi'
sete "engine_warn_deprecated is safe"    'engine_warn_deprecated vivlio 2>/dev/null'


echo "============ DISCOVERY ============"
setup
check "lists installed engines" "null pandoc-xslt vivlio" \
      "$(engines_list | sort | tr '\n' ' ' | sed 's/ $//')"
check "an installed engine exists" "0" "$(engine_exists vivlio; echo $?)"
check "an unknown one does not"    "1" "$(engine_exists nosuch; echo $?)"

# A half-installed engine is worse than an absent one: selecting it could only
# fail later, and less clearly.
setup
mkdir -p "$ENGINES_DIR/broken" && printf 'id=broken\n' > "$ENGINES_DIR/broken/engine.conf"
check "an engine with no convert is not listed" "" \
      "$(engines_list | grep '^broken$')"
setup


echo "============ THE ENTRY POINT ============"

# The only path pdfulator hardcodes is engine.conf; what it runs is named BY
# engine.conf. `./convert` is a default, not an assumption -- an engine may put
# its program wherever it likes and say so.
setup
check "an undeclared entry point defaults to ./convert" \
      "$ENGINES_DIR/vivlio/convert" "$(engine_entry vivlio)"

# The case that proves the declaration is actually followed. A default-shaped
# check would pass whether or not engine_entry read the conf file at all, so
# the fixture puts the program somewhere the default could never find it.
setup
mkdir -p "$ENGINES_DIR/declared/_nopayload"
{
	printf 'id=declared\n'
	printf 'convert = ./_nopayload/run\n'
} > "$ENGINES_DIR/declared/engine.conf"
cat > "$ENGINES_DIR/declared/_nopayload/run" <<'RUNEOF'
#!/bin/sh
printf 'declared engine ran\n'
RUNEOF
chmod +x "$ENGINES_DIR/declared/_nopayload/run"

check "a declared entry point is resolved" \
      "$ENGINES_DIR/declared/_nopayload/run" "$(engine_entry declared)"
check "and there is no ./convert to fall back on" "no" \
      "$([ -e "$ENGINES_DIR/declared/convert" ] && echo yes || echo no)"
check "the engine exists on the strength of it" "0" \
      "$(engine_exists declared; echo $?)"
check "and is listed" "declared" "$(engines_list | grep '^declared$')"
check "and is what actually runs" "declared engine ran" \
      "$(engine_convert declared - - '' 2>/dev/null)"

# Declared but absent is the half-installed case again, and must fail the same
# way rather than being listed on the strength of the declaration alone.
setup
mkdir -p "$ENGINES_DIR/missing"
{
	printf 'id=missing\n'
	printf 'convert = ./_nopayload/run\n'
} > "$ENGINES_DIR/missing/engine.conf"
check "a declared entry point that is not there is not listed" "" \
      "$(engines_list | grep '^missing$')"
check "nor does it exist" "1" "$(engine_exists missing; echo $?)"
setup
mkdir -p "$ENGINES_DIR/halfway" && : > "$ENGINES_DIR/halfway/convert"
chmod +x "$ENGINES_DIR/halfway/convert"
check "an engine with no conf is not listed" "" \
      "$(engines_list | grep '^halfway$')"


echo "============ CONF PARSING ============"
setup
check "reads a key"            "markdown-it" "$(engine_get vivlio parser)"
check "reads a later key"      "chromium"    "$(engine_get vivlio renderer)"
check "an absent key is empty" ""            "$(engine_get vivlio nosuchkey)"

# engine.conf is a file people edit, so it tolerates what editors leave behind.
setup
printf '# a comment\n\n  needs_runtime = spaced \nid=messy\n\tstyler=tabbed\t\n' \
	> "$ENGINES_DIR/vivlio/engine.conf"
# `needs_runtime = spaced` must mean what it looks like it means: whitespace
# around the = is invisible in an editor, so it cannot be significant.
check "spaces around = are ignored"  "spaced" "$(engine_get vivlio needs_runtime)"
check "trailing whitespace is trimmed" "tabbed" "$(engine_get vivlio styler)"

# The conf is read, never sourced: a downloaded engine must not be able to run
# code merely by being inspected.
setup
printf 'id=evil\ndescription=x\n' > "$ENGINES_DIR/vivlio/engine.conf"
printf 'touch "%s/PWNED"\n' "$BASE" >> "$ENGINES_DIR/vivlio/engine.conf"
engine_get vivlio id >/dev/null
check "reading a conf executes nothing" "absent" \
      "$([ -e "$BASE/PWNED" ] && echo present || echo absent)"


echo "============ SELECTION ============"
setup
check "defaults to vivlio"        "vivlio"      "$(engine_resolve)"
check "--engine wins"             "pandoc-xslt" "$(engine_resolve pandoc-xslt)"

# An unknown engine is an error, never a silent default: rendering with
# something other than what was asked for produces a plausible PDF that is
# wrong in a way only an eye catches. Same rule as themes (36236a6).
setup
check "an unknown engine fails"   "1" "$(engine_resolve nosuch >/dev/null 2>&1; echo $?)"
setup
engine_resolve nosuch >/dev/null 2>&1
check "and says so"               "1" "$(printf '%s' "$ERRMSG" | grep -c 'no engine named')"

# The internal test engine is selectable but not advertised.
setup
check "an internal engine is selectable" "null" "$(engine_resolve null)"

# ...and never sticks. Pinning null would be a trap with no way out: every
# later run would produce a blank PDF, and --list-engines hides internal
# engines, so it would show nothing in use to explain why.
setup
engine_pin null
check "an internal engine is not pinned" "vivlio" "$(engine_resolve)"

# The same reasoning applied to a pin file that already names one, whether
# hand-edited or left by an older version.
setup
mkdir -p "$(dirname "$ENGINE_CONF")" && printf 'null\n' > "$ENGINE_CONF"
check "an internal pin is ignored" "vivlio" "$(engine_resolve)"


echo "============ PINNING ============"
setup
engine_pin pandoc-xslt
check "a pin is remembered"  "pandoc-xslt" "$(engine_resolve)"
check "and --engine overrides it" "vivlio" "$(engine_resolve vivlio)"
check "pinning an unknown engine fails" "1" "$(engine_pin nosuch >/dev/null 2>&1; echo $?)"

# A pin naming an engine that has since been removed is not a typo: the user
# did choose it once, so the message says to choose again rather than to check
# the spelling.
setup
engine_pin pandoc-xslt
rm -rf "$ENGINES_DIR/pandoc-xslt"
ERRMSG=""
check "a stale pin fails"  "1" "$(engine_resolve >/dev/null 2>&1; echo $?)"
setup
engine_pin pandoc-xslt
rm -rf "$ENGINES_DIR/pandoc-xslt"
engine_resolve >/dev/null 2>&1
check "and says the pin is the problem" "1" \
      "$(printf '%s' "$ERRMSG" | grep -c 'pinned engine')"


echo "============ REQUIREMENTS ============"
setup
check "vivlio needs a JS runtime"    "0" "$(engine_needs_runtime vivlio; echo $?)"
check "vivlio needs a browser"       "0" "$(engine_needs_browser vivlio; echo $?)"
check "vivlio needs no docker"       "1" "$(engine_needs_docker vivlio; echo $?)"
# The whole point of per-engine requirements: a pandoc-xslt user never meets
# bun, and never pays for a browser search.
check "pandoc-xslt needs no runtime" "1" "$(engine_needs_runtime pandoc-xslt; echo $?)"
check "pandoc-xslt needs no browser" "1" "$(engine_needs_browser pandoc-xslt; echo $?)"
check "pandoc-xslt needs docker"     "0" "$(engine_needs_docker pandoc-xslt; echo $?)"


echo "============ DEPENDENCIES ============"
# Where an engine's dependencies live: under _nopayload/, beside the code that
# imports them. This had rotted to the engine root, and the failure was silent
# in the worst way -- the package.json test failed, `continue` skipped the
# engine, and every engine reported ready. `--install` then installed a runtime
# and a browser, said nothing about dependencies, and the render failed on the
# one path that had the location right.
#
# So the assertions are on both answers. "Ready when present" alone would still
# pass with the paths wrong.
setup
mkdir -p "$ENGINES_DIR/vivlio/_nopayload"
printf '{}\n' > "$ENGINES_DIR/vivlio/_nopayload/package.json"
check "not ready without node_modules" "1" "$(engines_deps_ready; echo $?)"

mkdir -p "$ENGINES_DIR/vivlio/_nopayload/node_modules"
check "ready once installed"           "0" "$(engines_deps_ready; echo $?)"

# A package.json at the engine root is not where dependencies live. If this
# passes while the _nopayload one is absent, the paths have rotted back.
setup
mkdir -p "$ENGINES_DIR/vivlio/node_modules"
printf '{}\n' > "$ENGINES_DIR/vivlio/package.json"
check "the engine root is not consulted" "0" "$(engines_deps_ready; echo $?)"

# An engine needing no runtime has no dependencies to miss -- otherwise a
# pandoc-xslt user is sent to install them forever.
setup
mkdir -p "$ENGINES_DIR/pandoc-xslt/_nopayload"
printf '{}\n' > "$ENGINES_DIR/pandoc-xslt/_nopayload/package.json"
check "a non-JS engine is not asked"   "0" "$(engines_deps_ready; echo $?)"


echo "============ DEPRECATION ============"
setup
check "a deprecated engine is flagged" "0" "$(engine_is_deprecated pandoc-xslt; echo $?)"
check "a current one is not"           "1" "$(engine_is_deprecated vivlio; echo $?)"
check "the warning names the engine"   "1" \
      "$(engine_warn_deprecated pandoc-xslt 2>&1 >/dev/null | grep -c 'pandoc-xslt.*deprecated')"
check "and is silent otherwise"        "" \
      "$(engine_warn_deprecated vivlio 2>&1 >/dev/null)"


echo "============ LISTING ============"
setup
check "the internal engine is hidden" "" "$(engines_describe | grep 'null')"
check "real engines are shown"        "2" \
      "$(engines_describe | grep -c 'The .* engine')"
check "the one in use is marked"      "1" \
      "$(engines_describe | grep -c '^\* vivlio')"
check "deprecation is shown"          "1" \
      "$(engines_describe | grep -c 'pandoc-xslt.*deprecated')"

setup
rm -rf "$ENGINES_DIR"/*
check "no engines is explicable" "1" "$(engines_describe | grep -c 'No engines')"


echo "============ PREPARE ============"
#
# First-run setup: the engine-specific half of the dependency split. The
# shared half (a runtime, a browser, a docker daemon) is the wrapper's and is
# tested where it lives; what is checked here is that `prepare` runs when it
# should, does not when it shouldn't, and that a failure stops the run.
#
# The version is pinned rather than read from a VERSION file, so these cases
# do not change meaning when the release does.
PDFULATOR_PREPARE_VERSION=test-1

# An engine whose prepare records that it ran, and exits how it is told to.
make_prepare() {  # make_prepare <id> <exit-status>
	cat > "$ENGINES_DIR/$1/prepare" <<EOF
#!/bin/sh
printf '%s\n' "$1" >> "$BASE/prepared"
exit $2
EOF
	chmod +x "$ENGINES_DIR/$1/prepare"
}

prep_setup() {  # prep_setup — the standard cast, plus a clean prepare log
	setup
	: > "$BASE/prepared"
}

# `grep -c` exits 1 on no matches, so a bare `|| echo 0` prints grep's own
# zero *and* the fallback. wc counts an empty file as zero without failing.
prep_ran() { wc -l < "$BASE/prepared" 2>/dev/null | tr -d ' '; }

prep_setup
make_prepare vivlio 0
engine_prepare vivlio
check "prepare runs the first time"  "1" "$(prep_ran)"
engine_prepare vivlio
check "and not the second"           "1" "$(prep_ran)"
check "the engine is marked ready"   "0" "$(engine_prepared vivlio; echo $?)"

# An engine with no prepare is the common case, not an error: most engines
# have nothing of their own to fetch.
prep_setup
check "no prepare is not a failure"  "0" "$(engine_prepare pandoc-xslt; echo $?)"
check "and it counts as prepared"    "0" "$(engine_prepared pandoc-xslt; echo $?)"

# The stamp lives under PDFULATOR_HOME, never in the engine directory: an
# engine directory is shipped content, and --uninstall tells shipped files
# from edited ones by hash. A stamp beside `convert` would make the engine
# look modified and outlive the uninstall that should have taken it.
prep_setup
make_prepare vivlio 0
engine_prepare vivlio
check "the stamp is in PDFULATOR_HOME" "0" \
      "$([ -f "$PDFULATOR_HOME/.prepared/vivlio" ]; echo $?)"
check "and not in the engine"          "1" \
      "$([ -f "$ENGINES_DIR/vivlio/.prepared" ]; echo $?)"

# A failed prepare is fatal, and leaves no stamp -- so the next run retries
# rather than recording a download that never happened.
prep_setup
make_prepare vivlio 1
check "a failing prepare fails"      "1" "$(engine_prepare vivlio 2>/dev/null; echo $?)"
check "and writes no stamp"          "1" "$(engine_prepared vivlio; echo $?)"
check "and says which engine"        "1" \
      "$(engine_prepare vivlio 2>/dev/null; printf '%s' "$ERRMSG" | grep -c 'vivlio')"

# An update invalidates every stamp at once: a new release may pin a different
# tool or a different image tag, and the alternative is each prepare inventing
# its own freshness check.
prep_setup
make_prepare vivlio 0
engine_prepare vivlio
PDFULATOR_PREPARE_VERSION=test-2
check "a new version is not prepared" "1" "$(engine_prepared vivlio; echo $?)"
engine_prepare vivlio
check "so prepare runs again"         "2" "$(prep_ran)"
PDFULATOR_PREPARE_VERSION=test-1

# The escape hatch, for CI and for these matrices: nothing should reach the
# network by accident. `force` -- which is what --prepare passes -- is not an
# accident, so it overrides.
# `VAR=1 somefunc` does not scope the variable to the call the way it does for
# a command: for a *function* POSIX leaves the assignment in the shell
# afterwards. Set and unset it explicitly, or it leaks into every later case.
prep_setup
make_prepare vivlio 0
PDFULATOR_NO_PREPARE=1
engine_prepare vivlio
check "NO_PREPARE skips it"          "0" "$(prep_ran)"
engine_prepare vivlio force
check "but force overrides it"       "1" "$(prep_ran)"
unset PDFULATOR_NO_PREPARE

# force re-runs a prepared engine, which is the whole purpose of --prepare:
# fetching now, on a connection you have, rather than during the first
# conversion on one you haven't.
prep_setup
make_prepare vivlio 0
engine_prepare vivlio
engine_prepare vivlio force
check "force ignores the stamp"      "2" "$(prep_ran)"

unset PDFULATOR_NO_PREPARE
PDFULATOR_PREPARE_VERSION=test-1


echo "============ DISPATCH ============"
setup
CHROME_PATH=/fake/chrome engine_convert vivlio /in.md /out.pdf /payload
check "the right engine ran" "vivlio" "$(cut -d'|' -f1 < "$BASE/ran")"
check "input, output and payload are passed" "/in.md|/out.pdf|/payload" \
      "$(cut -d'|' -f2,3,4 < "$BASE/ran")"
# The environment is the rest of the contract: an engine is told which browser
# to use rather than going to look.
check "CHROME_PATH is passed through" "/fake/chrome" "$(cut -d'|' -f5 < "$BASE/ran")"
# PDFULATOR_DEFAULTS is deliberately *not* set: there is no defaults directory
# any more, and everything an engine used to find there arrives in the staged
# theme it is handed as its third argument.
check "no defaults directory is pointed at" "no-defaults" \
      "$(cut -d'|' -f6 < "$BASE/ran")"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
