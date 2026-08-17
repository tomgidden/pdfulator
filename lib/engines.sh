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
		[ "$_eg_key" = "$_eg_line" ] && continue   # no '=': not a setting
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
	elif [ -s "$ENGINE_CONF" ]; then
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
engine_pin() {  # engine_pin <id>
	engine_exists "$1" || { engines_error "no engine named \"$1\"."; return 1; }
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
		engine_is_internal "$_ed_id" && continue
		_ed_any=1

		_ed_mark="  "
		[ "$_ed_id" = "$_ed_current" ] && _ed_mark="* "

		_ed_note=""
		engine_is_deprecated "$_ed_id" && _ed_note="  (deprecated)"

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
	[ -n "$_ed_current" ] && printf '\n* = in use\n'
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
