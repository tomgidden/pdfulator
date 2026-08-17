#!/bin/sh
# Engine discovery, selection and pinning.
#
# Built against fabricated engines rather than the real ones, so the cases can
# cover combinations that do not exist yet -- a deprecated engine, a docker
# engine, an engine with no runtime -- and so they stay fixed while the real
# engines change. Selection is what is under test, not any renderer.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
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


echo "============ DISPATCH ============"
setup
CHROME_PATH=/fake/chrome engine_convert vivlio /in.md /out.pdf /theme
check "the right engine ran" "vivlio" "$(cut -d'|' -f1 < "$BASE/ran")"
check "input, output and theme are passed" "/in.md|/out.pdf|/theme" \
      "$(cut -d'|' -f2,3,4 < "$BASE/ran")"
# The environment is the rest of the contract: an engine is told which browser
# to use and where the shared assets are, rather than going to look.
check "CHROME_PATH is passed through" "/fake/chrome" "$(cut -d'|' -f5 < "$BASE/ran")"
check "defaults are pointed at" "$BASE/dist/defaults" "$(cut -d'|' -f6 < "$BASE/ran")"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
