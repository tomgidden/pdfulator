# lib/theme.sh — theme resolution.
#
# Turns whatever the user wrote after --theme into one absolute directory, which
# is the third argument of the engine contract. Engines receive a directory and
# nothing else: no name to look up, no search path, no notion of where themes
# live. That is deliberate -- a container engine's filesystem is not the user's,
# so resolution has to happen on this side of the boundary, before the mount is
# even constructed.
#
# Ported from resolveTheme() in the v2 pdfulator.js, which owned this when there
# was only one engine to own it for. Requires lib/paths.sh for abspath.
#
# Search order for a *name*:
#   1. <cwd>/themes/<name>/
#   2. $PDFULATOR_HOME/themes/<name>/
#   3. <install dir>/themes/<name>/
# A *path* -- absolute, or starting ./ or ../ -- is taken as given, unsearched.


# Where the built-in theme lives, and where installed themes are looked for.
# $PDFULATOR_DIR is set by the caller (the wrapper knows where it was unpacked);
# it falls back to this file's parent so that sourcing lib/theme.sh from a
# checkout, as the tests do, works without ceremony.
: "${PDFULATOR_DIR:=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)}"
: "${PDFULATOR_HOME:=$HOME/.local/share/pdfulator}"

BUILTIN_THEME="$PDFULATOR_DIR/theme"


# How resolution reports failure. Overridable by the caller, as jobs_error is,
# so tests can capture the message instead of the terminal.
theme_error() {  # theme_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# Is this argument a path rather than a name?
#
# The same three-way test as the JS: a leading /, ./ or ../ means the user has
# told us exactly where, and we must not go looking anywhere else. A bare
# `themes/foo` is deliberately *not* a path -- it is a name that happens to
# contain a slash, and searching for it is the more useful reading.
theme_is_path() {  # theme_is_path <arg>
	case $1 in
		/*|./*|../*) return 0 ;;
		*)           return 1 ;;
	esac
}


# Resolve a theme, printing the absolute directory on stdout.
#
# Not finding one is an error, not a fallback (commit 36236a6). Quietly
# rendering with the default theme means a typo produces a plausible-looking
# PDF in the wrong style -- the kind of mistake you only catch by eye, after
# sending it.
theme_resolve() {  # theme_resolve [name-or-path]
	# No --theme at all: the built-in. This is the only path to the default;
	# a *named* theme never falls back to it.
	if [ -z "${1:-}" ]; then
		printf '%s\n' "$(abspath "$BUILTIN_THEME")"
		return 0
	fi

	if theme_is_path "$1"; then
		if [ ! -d "$1" ]; then
			theme_error "theme directory not found: $1"
			return 1
		fi
		printf '%s\n' "$(abspath "$1")"
		return 0
	fi

	# Candidates, deduplicated: cwd and the install directory coincide when
	# running from a checkout, and listing the same path twice in the error
	# below reads like a bug rather than like thoroughness.
	_th_seen=""
	_th_found=""
	for _th_base in "$PWD" "$PDFULATOR_HOME" "$PDFULATOR_DIR"; do
		_th_cand="$_th_base/themes/$1"

		case "	$_th_seen	" in
			*"	$_th_cand	"*) continue ;;
		esac
		_th_seen="$_th_seen	$_th_cand"

		if [ -z "$_th_found" ] && [ -d "$_th_cand" ]; then
			_th_found=$_th_cand
		fi
	done

	if [ -n "$_th_found" ]; then
		printf '%s\n' "$(abspath "$_th_found")"
		return 0
	fi

	# Report every place looked, in order. A theme that exists but under the
	# wrong root is the common case, and the list is what makes that visible.
	theme_error "no theme named \"$1\"."
	printf 'Looked in:\n' >&2
	printf '%s' "$_th_seen" | tr '	' '\n' | while read -r _th_line; do
		[ -n "$_th_line" ] && printf '  %s\n' "$_th_line" >&2
	done
	return 1
}
