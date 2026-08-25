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
	# IFS= and the `|| [ -n ... ]` guard for the reasons theme_chain gives
	# below: without them the first candidate is merged into the empty leading
	# field and the last is dropped for want of a trailing newline.
	printf '%s' "$_th_seen" | tr '	' '\n' |
	while IFS= read -r _th_line || [ -n "$_th_line" ]; do
		if [ -n "$_th_line" ]; then printf '  %s\n' "$_th_line" >&2; fi
	done
	return 1
}


# --- The cascade ---------------------------------------------------------------
#
# A theme is rarely written from nothing. `theme-palatino` wants everything
# `theme-classic` does with a different body font; `theme-classic` wants
# everything `theme-default` does plus a layout. So a theme names its parent
# and supplies only its differences.
#
#   # themes/palatino/theme.conf
#   extends = classic
#
# and within a theme, files are looked for per engine, then per styler, then
# plain. `stylers/` rather than only `engines/` because vivlio and
# vivlio-docker are the same renderer -- their CSS is identical by
# construction, and a theme that had to write it twice would have two copies
# to keep in step. `styler` is already declared by every engine.conf.


# The parent chain of a theme, root first, one absolute directory per line.
#
# Root first because that is cascade order: the floor is applied, then each
# refinement over it. Callers pass the whole list to fonts_merge or concatenate
# CSS in the order given.
#
# Cycles are detected rather than run into: a theme extending itself, directly
# or round a loop, is a mistake worth naming, and without the check it hangs.
# The depth cap catches the same class of thing when a chain is merely absurd.
theme_chain() {  # theme_chain <theme-dir>
	_tc_dir=$(abspath "$1")
	_tc_chain=""
	_tc_seen=""
	_tc_depth=0

	while [ -n "$_tc_dir" ]; do
		if [ ! -d "$_tc_dir" ]; then
			theme_error "theme directory not found: $_tc_dir"
			return 1
		fi

		case "	$_tc_seen	" in
			*"	$_tc_dir	"*)
				theme_error "theme inheritance loops back to \"$(basename -- "$_tc_dir")\"."
				printf 'The chain so far:\n' >&2
				# Two things this loop needs and an ordinary `read -r` does
				# not give. IFS= , because read otherwise strips each field's
				# leading blanks and $_tc_seen begins with a tab -- so the
				# empty first field is swallowed together with the path after
				# it. And `|| [ -n ... ]`, because tr leaves no trailing
				# newline, so read reports false on the final field and would
				# drop it. Same idiom, same reasons, as conf_get.
				printf '%s' "$_tc_seen" | tr '	' '\n' |
				while IFS= read -r _tc_l || [ -n "$_tc_l" ]; do
					if [ -n "$_tc_l" ]; then printf '  %s\n' "$_tc_l" >&2; fi
				done
				return 1
				;;
		esac
		_tc_seen="$_tc_seen	$_tc_dir"

		_tc_depth=$((_tc_depth + 1))
		if [ "$_tc_depth" -gt 16 ]; then
			theme_error "theme inheritance is more than 16 deep; giving up."
			return 1
		fi

		# Prepended, so the list comes out root-first from a walk that goes
		# child-to-parent.
		_tc_chain="$_tc_dir${_tc_chain:+
}$_tc_chain"

		_tc_parent=""
		if [ -f "$_tc_dir/theme.conf" ]; then
			_tc_parent=$(conf_get "$_tc_dir/theme.conf" extends)
		fi
		[ -n "$_tc_parent" ] || break

		# A parent is resolved the same way --theme is, so `extends = classic`
		# finds the same theme the user could have named. Resolution is
		# relative to nothing -- it searches -- which is what lets a user's own
		# theme extend a shipped one.
		# The child's name is taken first: theme_resolve overwrites $_tc_dir,
		# so reading it afterwards names the wrong theme -- or, when
		# resolution failed and printed nothing, no theme at all.
		_tc_child=$(basename -- "$_tc_dir")
		_tc_dir=$(theme_resolve "$_tc_parent") || {
			theme_error "theme \"$_tc_child\" extends \"$_tc_parent\", which was not found."
			return 1
		}
	done

	printf '%s\n' "$_tc_chain"
}


# Find one file across a theme chain, most specific first.
#
#   theme_file <chain> <engine> <styler> <name>
#
# Within each theme, in order:
#   engines/<engine>/<name>   this exact engine, for a genuine difference
#   stylers/<styler>/<name>   this renderer, docker or not
#   <name>                    engine-agnostic
#
# and across the chain, the *child* wins: a theme overriding article.tmpl
# replaces its parent's rather than adding to it. Prints every match, most
# specific first, so a caller wanting one takes the first line and a caller
# wanting to concatenate a cascade (CSS) reverses it.
theme_file() {  # theme_file <chain> <engine> <styler> <name>
	_tf_chain=$1
	_tf_engine=$2
	_tf_styler=$3
	_tf_name=$4

	# The chain arrives root-first; specificity wants child-first, so it is
	# walked in reverse. `sed '1!G;h;$!d'` is the portable tac -- neither tac
	# nor `tail -r` is on both macOS and Linux.
	printf '%s\n' "$_tf_chain" | sed '1!G;h;$!d' | while IFS= read -r _tf_dir; do
		[ -n "$_tf_dir" ] || continue
		if [ -n "$_tf_engine" ] && [ -f "$_tf_dir/engines/$_tf_engine/$_tf_name" ]; then
			printf '%s\n' "$_tf_dir/engines/$_tf_engine/$_tf_name"
		fi
		if [ -n "$_tf_styler" ] && [ -f "$_tf_dir/stylers/$_tf_styler/$_tf_name" ]; then
			printf '%s\n' "$_tf_dir/stylers/$_tf_styler/$_tf_name"
		fi
		if [ -f "$_tf_dir/$_tf_name" ]; then
			printf '%s\n' "$_tf_dir/$_tf_name"
		fi
	done
}


# The single most specific match, or nothing. What a caller wanting *the*
# article.tmpl uses.
theme_file_one() {  # theme_file_one <chain> <engine> <styler> <name>
	theme_file "$@" | head -1
}
