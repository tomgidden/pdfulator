# lib/conf.sh — reading flat key=value configuration.
#
# The lowest layer, below paths.sh: engine.conf, theme.conf and fonts.conf are
# all this format, and all read by conf_get.
#
# The format is flat key=value, chosen so it needs no parser. Such a file is
# *not* sourced, though it would usually be valid sh: sourcing a config file
# makes every directory containing one into executable code, so a downloaded
# engine -- or, once themes can be shared, a downloaded theme -- could run
# anything merely by being looked at. Reading it with a case-and-cut loop costs
# a few lines and removes that entirely.
#
# That reasoning is why fonts.conf is this format rather than JSON. A theme is
# the thing users will swap and share, so a theme must be inert data; and the
# alternative host-side parsers are worse than the format is ugly -- jq is not
# a dependency this tool has, and a JSON parser written in sh is a bug farm.
#
# Sourced, never executed. Requires nothing.


# Read one key from a flat key=value file. Empty when absent, so a missing key
# and an empty value are the same thing -- which suits every key that uses
# this, all of which are optional with a sensible empty meaning.
#
# Tolerant of comments, blank lines and surrounding whitespace, because these
# are files people edit. Only the first occurrence counts.
#
# Returns 1 only when the *file* is missing, which callers distinguish from an
# absent key: an engine without an engine.conf is not an engine, while an
# engine.conf without a `deprecated` line is perfectly ordinary.
conf_get() {  # conf_get <file> <key>
	[ -f "$1" ] || return 1

	while IFS= read -r _cg_line || [ -n "$_cg_line" ]; do
		# Strip a leading blank run, then skip comments and empties.
		_cg_line=${_cg_line#"${_cg_line%%[! 	]*}"}
		case $_cg_line in
			''|'#'*) continue ;;
		esac

		# Whitespace around the `=` is invisible in an editor, so
		# `needs_runtime = js` must mean what it looks like it means. The key
		# is compared with its own trailing blanks removed, and the value with
		# blanks stripped from both ends.
		_cg_key=${_cg_line%%=*}
		# No '=' at all: not a setting. `if`, not `&&`, throughout this file --
		# a bare `[ ... ] && ...` whose test is false is a failing command, and
		# under set -e that aborts the caller. See browser_gather.
		if [ "$_cg_key" = "$_cg_line" ]; then continue; fi
		_cg_key=${_cg_key%"${_cg_key##*[! 	]}"}
		[ "$_cg_key" = "$2" ] || continue

		_cg_val=${_cg_line#*=}
		_cg_val=${_cg_val#"${_cg_val%%[! 	]*}"}
		printf '%s\n' "${_cg_val%"${_cg_val##*[! 	]}"}"
		return 0
	done < "$1"

	printf '\n'
	return 0
}


# Every key in a flat key=value file, one per line, in file order.
#
# Used to discover what a fonts.conf declares, since roles are not a fixed
# list: a theme may name `body`, `heading` and `mono`, and may also name
# `pullquote`. Duplicates are left in -- conf_get takes the first occurrence,
# and callers that care deduplicate.
conf_keys() {  # conf_keys <file>
	[ -f "$1" ] || return 1

	while IFS= read -r _ck_line || [ -n "$_ck_line" ]; do
		_ck_line=${_ck_line#"${_ck_line%%[! 	]*}"}
		case $_ck_line in
			''|'#'*) continue ;;
		esac

		_ck_key=${_ck_line%%=*}
		if [ "$_ck_key" = "$_ck_line" ]; then continue; fi
		printf '%s\n' "${_ck_key%"${_ck_key##*[! 	]}"}"
	done < "$1"

	return 0
}


# The sha256 of a file, as bare hex.
#
# Lives here rather than in paths.sh because its callers are all config-shaped:
# verifying a downloaded font against the checksum in a fonts.conf, and keying
# a staging directory on the conf files that produced it. install.sh has its
# own copy for the same reason lib/container.sh duplicates abspath -- it runs
# before there is a lib/ to source.
#
# sha256sum on Linux, shasum on macOS, which has no sha256sum. Both print
# "<hash>  <file>", so the cut is shared.
conf_hash_file() {  # conf_hash_file <path>
	[ -f "$1" ] || return 1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}


# The sha256 of stdin, as bare hex. Used for staging keys, which are computed
# from a string built up in memory rather than from a file on disk.
conf_hash_string() {  # printf '%s' "$s" | conf_hash_string
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
}
