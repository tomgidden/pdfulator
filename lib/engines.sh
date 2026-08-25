# lib/engines.sh — engine discovery, selection and dispatch.
#
# An engine is a directory under engines/ containing an `engine.conf` and an
# executable `convert`. That is the whole of it: adding one is dropping in a
# directory, which is the point of the refactor -- the future pagedjs engine
# should be a small addition rather than a fork of the tool.
#
# Requires lib/paths.sh.
#
# engine.conf is flat key=value, chosen so it needs no parser. It is *not*
# sourced, though it would be valid sh: sourcing a config file makes every
# engine directory executable code, so a downloaded engine could run anything
# merely by being looked at. Reading it with a case-and-cut loop costs a few
# lines and removes that entirely.


ENGINES_DIR="${PDFULATOR_ENGINES:-$PDFULATOR_DIR/engines}"

# Where the choice is remembered, beside the browser and runtime pins.
ENGINE_CONF="$PDFULATOR_HOME/.engine"

# The engine used when nothing is pinned and nothing is asked for.
ENGINE_DEFAULT=vivlio


engines_error() {  # engines_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# Every installed engine, one id per line, alphabetically.
#
# The listing is of what is *present*, not of what is known to exist: engines
# arrive as separate downloads, so a user has the ones they took. An engine
# missing its convert or its conf is not listed, since selecting it could only
# fail later and more confusingly.
engines_list() {
	[ -d "$ENGINES_DIR" ] || return 0
	for _el in "$ENGINES_DIR"/*; do
		[ -d "$_el" ] || continue
		[ -f "$_el/engine.conf" ] || continue
		[ -x "$_el/convert" ] || continue
		basename -- "$_el"
	done
}


# Read one key from an engine's conf. Empty when absent, so a missing key and
# an empty value are the same thing -- which suits every key here, all of
# which are optional with a sensible empty meaning.
#
# Tolerant of comments, blank lines and surrounding whitespace, because
# engine.conf is a file people edit. Only the first occurrence counts.
engine_get() {  # engine_get <id> <key>
	_eg_file="$ENGINES_DIR/$1/engine.conf"
	[ -f "$_eg_file" ] || return 1

	while IFS= read -r _eg_line || [ -n "$_eg_line" ]; do
		# Strip a leading blank run, then skip comments and empties.
		_eg_line=${_eg_line#"${_eg_line%%[! 	]*}"}
		case $_eg_line in
			''|'#'*) continue ;;
		esac

		# Whitespace around the `=` is invisible in an editor, so
		# `needs_runtime = js` must mean what it looks like it means. The key
		# is compared with its own trailing blanks removed, and the value with
		# blanks stripped from both ends.
		_eg_key=${_eg_line%%=*}
		# No '=' at all: not a setting. `if`, not `&&`, throughout this file --
		# a bare `[ ... ] && ...` whose test is false is a failing command, and
		# under set -e that aborts the caller. See browser_gather.
		if [ "$_eg_key" = "$_eg_line" ]; then continue; fi
		_eg_key=${_eg_key%"${_eg_key##*[! 	]}"}
		[ "$_eg_key" = "$2" ] || continue

		_eg_val=${_eg_line#*=}
		_eg_val=${_eg_val#"${_eg_val%%[! 	]*}"}
		printf '%s\n' "${_eg_val%"${_eg_val##*[! 	]}"}"
		return 0
	done < "$_eg_file"

	printf '\n'
	return 0
}


engine_exists() {  # engine_exists <id>
	[ -n "${1:-}" ] || return 1
	[ -f "$ENGINES_DIR/$1/engine.conf" ] && [ -x "$ENGINES_DIR/$1/convert" ]
}


# An engine not meant for users: the null test engine. Hidden from the listing
# rather than removed from it, so it can still be selected deliberately.
engine_is_internal() {  # engine_is_internal <id>
	[ "$(engine_get "$1" internal)" = yes ]
}


# The engine to use, given what was asked for.
#
# Order: an explicit --engine, then the pin, then the default. A missing or
# unknown engine is an error rather than a silent fall back to the default --
# the same rule themes follow (36236a6), and for the same reason: quietly
# rendering with something other than what was asked for produces a
# plausible-looking PDF that is wrong in a way only an eye can catch.
engine_resolve() {  # engine_resolve [requested]
	_er_want=${1:-}
	_er_src=""

	if [ -n "$_er_want" ]; then
		_er_src="--engine"
	elif [ -s "$ENGINE_CONF" ] && ! engine_is_internal "$(cat "$ENGINE_CONF")"; then
		# An internal engine in the pin file is ignored rather than obeyed:
		# engine_pin refuses to write one, so its presence means a hand-edit or
		# a file left by an older version, and honouring it would silently turn
		# every conversion into a blank page.
		_er_want=$(cat "$ENGINE_CONF")
		_er_src="the pinned engine"
	else
		_er_want=$ENGINE_DEFAULT
		_er_src="the default engine"
	fi

	if ! engine_exists "$_er_want"; then
		# A pin naming an engine that has since been removed is a different
		# situation from a typo, and is worth saying so: the user did choose
		# this once, and the fix is to choose again rather than to correct a
		# spelling.
		if [ "$_er_src" = "the pinned engine" ]; then
			engines_error "the pinned engine is not installed: $_er_want

Choose another with --engine <id>, or see --list-engines."
		else
			engines_error "no engine named \"$_er_want\" ($_er_src).

Installed engines:$(engines_list | grep -v '^null$' | sed 's/^/
  /')"
		fi
		return 1
	fi

	printf '%s\n' "$_er_want"
	return 0
}


# Everything the engine needs settled before it runs, reported as the
# requirements it declares. The wrapper acts on these -- resolving a runtime
# only for needs_runtime=js, a browser only for needs_browser=yes -- which is
# what keeps a pandoc-xslt user from ever meeting bun.
engine_needs_runtime() { [ "$(engine_get "$1" needs_runtime)" = js ]; }
engine_needs_browser() { [ "$(engine_get "$1" needs_browser)" = yes ]; }
engine_needs_docker()  { [ "$(engine_get "$1" needs_docker)" = yes ]; }
engine_is_deprecated() { [ "$(engine_get "$1" deprecated)" = yes ]; }


# Warn once per run that an engine is on its way out. To stderr, since stdout
# may be the PDF.
engine_warn_deprecated() {  # engine_warn_deprecated <id>
	engine_is_deprecated "$1" || return 0
	printf 'Warning: the %s engine is deprecated and may be removed.\n' "$1" >&2
	printf 'See --list-engines for the alternatives.\n' >&2
}


# Pin a choice, so it holds for later runs.
#
# Internal engines are used but never pinned. Pinning `null` would be a trap
# with no way out: every later run would produce a blank PDF, and the listing
# that ought to explain why hides internal engines, so it would show no engine
# in use at all. `--engine null` therefore applies to that run only, which is
# all a test engine is ever wanted for.
engine_pin() {  # engine_pin <id>
	engine_exists "$1" || { engines_error "no engine named \"$1\"."; return 1; }
	if engine_is_internal "$1"; then return 0; fi
	mkdir -p -- "$(dirname -- "$ENGINE_CONF")"
	printf '%s\n' "$1" > "$ENGINE_CONF"
	return 0
}


# The human-readable listing behind --list-engines.
#
# Internal engines are omitted; deprecated ones are shown, marked, because a
# user running one needs to know, and a user choosing one needs to be warned
# off. The current choice is marked too, since "which engine am I using?" is
# the question this command is most often asked to answer.
engines_describe() {
	_ed_current=$(engine_resolve 2>/dev/null) || _ed_current=""

	_ed_any=0
	for _ed_id in $(engines_list); do
		if engine_is_internal "$_ed_id"; then continue; fi
		_ed_any=1

		_ed_mark="  "
		if [ "$_ed_id" = "$_ed_current" ]; then _ed_mark="* "; fi

		_ed_note=""
		if engine_is_deprecated "$_ed_id"; then _ed_note="  (deprecated)"; fi

		printf '%s%-16s %s%s\n' "$_ed_mark" "$_ed_id" \
		       "$(engine_get "$_ed_id" description)" "$_ed_note"

		# The pipeline, indented under its engine. This is the metadata the
		# plan settled on as descriptive rather than configurable: it tells a
		# user what they are getting without offering dials that do not exist.
		printf '  %-16s   %s -> %s -> %s\n' "" \
		       "$(engine_get "$_ed_id" parser)" \
		       "$(engine_get "$_ed_id" styler)" \
		       "$(engine_get "$_ed_id" renderer)"
	done

	[ "$_ed_any" = 1 ] || printf 'No engines are installed.\n'
	if [ -n "$_ed_current" ]; then printf '\n* = in use\n'; fi
	return 0
}


# Has every JS engine got its dependencies?
#
# Only engines declaring needs_runtime=js are asked about: an engine that needs
# no runtime has no node_modules to be missing, and treating its absence as
# "not ready" would send a pandoc-xslt user to install dependencies forever.
engines_deps_ready() {
	for _edr in $(engines_list); do
		engine_needs_runtime "$_edr" || continue
		[ -f "$ENGINES_DIR/$_edr/package.json" ] || continue
		[ -d "$ENGINES_DIR/$_edr/node_modules" ] || return 1
	done
	return 0
}


# --- First-run preparation ---------------------------------------------------
#
# An engine's own tools -- pandoc, pagedjs-cli, a FOP jar, an API endpoint --
# are fetched on first use rather than shipped, so the distribution stays one
# small tarball and a user downloads only what the engines they actually run
# require.
#
# The division of labour is the point, and it is not the obvious one. Anything
# two engines could share is the *wrapper's* to fetch: a runtime, a browser,
# the docker daemon. One bun serves vivlio and every JS engine after it; one
# Chromium serves vivlio and the non-container pagedjs engine to come. If each
# engine fetched its own, two engines would race to install the same copy and
# a user would pay twice for one download. Those live in pdfulator.sh, beside
# the needs_runtime/needs_browser/needs_docker checks that already act on them.
#
# What is left is what only this engine could want, and that is `prepare`:
#
#   engines/<id>/prepare        optional, executable, no arguments
#
# It runs with the environment `convert` gets -- $PDFULATOR_RUNTIME,
# $CHROME_PATH, $PDFULATOR_DOCKER are already settled by the time it is called,
# which is exactly why the shared resources belong to the wrapper. Exit 0 means
# ready.
#
# The rule for a new engine, in one line: if two engines could want the same
# copy, the wrapper fetches it; otherwise `prepare` does.

# Where "this engine has been prepared" is recorded.
#
# Under $PDFULATOR_HOME, not in the engine's own directory. An engine directory
# is shipped content, and --uninstall tells shipped files from user-modified
# ones by hash: a stamp written next to `convert` would make the engine look
# edited and would survive an uninstall that should have taken it.
engine_stamp() {  # engine_stamp <id>
	printf '%s/.prepared/%s\n' "$PDFULATOR_HOME" "$1"
}


# Is this engine ready to convert?
#
# The stamp holds the version that prepared it, so an --update invalidates
# every engine at once: a new release may pin a different pandoc or a different
# image tag, and the alternative is each `prepare` inventing its own freshness
# check. Re-preparing after an update is cheap when nothing changed -- a
# `docker pull` of a current image is a no-op -- and correct when it did.
engine_prepared() {  # engine_prepared <id>
	_ep_file=$(engine_stamp "$1")
	[ -s "$_ep_file" ] || return 1
	[ "$(head -1 "$_ep_file" | tr -d ' \t\r')" = "$(engine_prepare_version)" ]
}


# What a stamp is compared against. Split out so tests can pin it, and so the
# lookup has one home rather than being repeated at both call sites.
engine_prepare_version() {
	if [ -n "${PDFULATOR_PREPARE_VERSION:-}" ]; then
		printf '%s\n' "$PDFULATOR_PREPARE_VERSION"
	elif [ -s "${VERSION_FILE:-}" ]; then
		head -1 "$VERSION_FILE" | tr -d ' \t\r'
	else
		printf 'unknown\n'
	fi
}


# Run an engine's first-run setup, at most once per version.
#
# `force` re-runs regardless of the stamp: that is `--prepare` said out loud,
# for a user about to go offline or one whose half-finished download needs
# retrying.
#
# An engine with no `prepare` is ready by definition -- most are. That is not
# an error and not a warning; it is the common case, and the stamp is still
# written so the answer is settled without a stat of the engine directory on
# every run.
engine_prepare() {  # engine_prepare <id> [force]
	_epr_id=$1
	_epr_force=${2:-}

	# The escape hatch for CI and for the test matrices, which have no network
	# and no business fetching anything. An explicit `force` -- which is
	# `--prepare` -- overrides it: the variable guards against preparing by
	# accident, and asking for it is not an accident.
	if [ -n "${PDFULATOR_NO_PREPARE:-}" ] && [ -z "$_epr_force" ]; then
		return 0
	fi

	if [ -z "$_epr_force" ] && engine_prepared "$_epr_id"; then return 0; fi

	_epr_script="$ENGINES_DIR/$_epr_id/prepare"
	if [ -x "$_epr_script" ]; then
		printf 'Preparing the %s engine...\n' "$_epr_id" >&2
		PDFULATOR_HOME="$PDFULATOR_HOME" \
		PDFULATOR_DEFAULTS="${PDFULATOR_DEFAULTS:-$PDFULATOR_DIR/defaults}" \
			"$_epr_script" || {
				# Fatal, not a warning. The engine has said it is not ready,
				# and running `convert` anyway trades one clear message for a
				# failure further in -- or, worse, a PDF rendered with
				# whatever was left over from a previous attempt.
				engines_error "the $_epr_id engine could not complete setup."
				return 1
			}
	fi

	# Only on success, so a failed run is retried next time rather than being
	# recorded as done.
	mkdir -p -- "$(dirname -- "$(engine_stamp "$_epr_id")")" || return 1
	engine_prepare_version > "$(engine_stamp "$_epr_id")"
	return 0
}


# Run one conversion.
#
# The environment is the interface: CHROME_PATH and PDFULATOR_RUNTIME are
# already settled by the caller, and the engine is told rather than left to
# find out. Exported here rather than by each engine so that every engine sees
# the same contract.
engine_convert() {  # engine_convert <id> <input|-> <output|-> <theme-dir>
	_ec_id=$1
	shift

	PDFULATOR_HOME="$PDFULATOR_HOME" \
	PDFULATOR_DEFAULTS="${PDFULATOR_DEFAULTS:-$PDFULATOR_DIR/defaults}" \
		"$ENGINES_DIR/$_ec_id/convert" "$@"
}
