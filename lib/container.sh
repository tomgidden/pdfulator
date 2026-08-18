# lib/container.sh — running an engine inside a container.
#
# Every container engine's `convert` does the same job: translate the engine
# contract into a `docker run`. A container cannot see the host's filesystem,
# so each of the three contract paths becomes a mount plus the path it has
# inside the image.
#
# That translation is identical for vivlio-docker and pandoc-pagedjs, and will
# be for pandoc-xslt: the same read-only input directory, the same writable
# output directory, the same uid, the same $HOME. Only two things differ per
# engine -- its name, for messages, and where its built-in theme lives inside
# its own image.
#
# Shared rather than copied because the parts that are easy to get wrong are
# the parts every engine needs. The crashpad workaround and the
# space-in-a-path handling below were each found once, painfully; a second
# engine with its own copy would be a second engine waiting to be found not to
# have them.
#
# Sourced by an engine's convert, which sets CONTAINER_ENGINE and
# CONTAINER_THEME and then calls container_run. Requires nothing else -- an
# engine's convert is exec'd by the wrapper, not sourced into it, so this file
# cannot assume lib/paths.sh is present.


# Resolve to an absolute path without requiring the leaf to exist.
#
# `docker -v relative/path:/in` is not a bind mount: docker reads a source
# without a leading slash as a *named volume*, creates it empty, and mounts
# that. The conversion then reads an empty directory and reports an empty
# document -- a wrong answer rather than an error, which is the worst kind.
#
# Duplicated from lib/paths.sh rather than sourced from it, deliberately: an
# engine runs as its own process and may be invoked directly, so it cannot
# rely on the wrapper's library being loaded.
container_abs() {  # container_abs <path>
	_ca_dir=$(dirname -- "$1")
	_ca_base=$(basename -- "$1")
	if [ -d "$_ca_dir" ]; then
		_ca_dir=$(cd -- "$_ca_dir" && pwd)
	fi
	case $_ca_dir in
		*/) printf '%s%s\n' "$_ca_dir" "$_ca_base" ;;
		*)  printf '%s/%s\n' "$_ca_dir" "$_ca_base" ;;
	esac
}


# The image this engine runs.
#
# Read from engine.conf rather than hardcoded, so the tag an engine declares
# and the tag it runs cannot disagree, and so a user can point at their own
# build by editing one line. $PDFULATOR_IMAGE overrides it for a one-off.
#
# Parsed with sed rather than sourced, for the reason lib/engines.sh gives:
# sourcing a config file makes every engine directory executable code.
container_image() {  # container_image <engine-dir>
	if [ -n "${PDFULATOR_IMAGE:-}" ]; then
		printf '%s\n' "$PDFULATOR_IMAGE"
		return 0
	fi
	[ -f "$1/engine.conf" ] || return 1
	_ci=$(sed -n 's/^[[:space:]]*image[[:space:]]*=[[:space:]]*//p' \
	      "$1/engine.conf" | head -1)
	# Trailing blanks are invisible in an editor and would become part of the
	# tag, giving a pull failure that names an image looking exactly right.
	printf '%s\n' "$(printf '%s' "$_ci" | sed 's/[[:space:]]*$//')"
}


# Convert one document in a container.
#
#   container_run <engine-dir> <input|-> <output|-> <theme-dir>
#
# Expects two variables from the calling engine:
#   CONTAINER_ENGINE  the engine's id, used in messages
#   CONTAINER_THEME   where its built-in theme lives inside its own image
container_run() {  # container_run <engine-dir> <in> <out> <theme>
	_cr_dir=$1
	_cr_in=$2
	_cr_out=$3
	_cr_theme=${4:-}

	_cr_name=${CONTAINER_ENGINE:-container}
	_cr_builtin=${CONTAINER_THEME:-/theme}

	[ -n "$_cr_in" ]  || { echo "$_cr_name: no input given"  >&2; return 2; }
	[ -n "$_cr_out" ] || { echo "$_cr_name: no output given" >&2; return 2; }

	_cr_image=$(container_image "$_cr_dir") || _cr_image=""
	[ -n "$_cr_image" ] || {
		echo "$_cr_name: no image configured (image= in engine.conf)." >&2
		return 1
	}

	_cr_docker=${PDFULATOR_DOCKER:-docker}
	command -v "$_cr_docker" >/dev/null 2>&1 || {
		echo "$_cr_name: $_cr_docker is not installed or not on PATH." >&2
		echo "Install Docker, or use the bundled engine: pdfulator --engine vivlio" >&2
		return 1
	}

	# Mounts and flags are accumulated as they are decided, then handed to
	# docker in one place at the end. Flags are plain words and live in
	# $_cr_flags; mounts may contain spaces (a path like ~/Documents/My Notes
	# is entirely ordinary) so they go into the positional parameters, which
	# survive word-splitting where a string would not.
	_cr_flags="--rm --init"
	set --

	# --- Input ---------------------------------------------------------------
	#
	# The file's *directory* is mounted, not the file. Two reasons, and the
	# second is the one that bites: an image reference like `![](fig.png)`
	# resolves relative to the document, so a lone file arrives with its
	# illustrations missing; and bind-mounting a single file pins an inode, so
	# an editor that saves by write-and-rename (most of them) leaves the
	# container looking at the deleted original.
	#
	# Read-only: an engine converting a document has no business writing next
	# to it.
	if [ "$_cr_in" = "-" ]; then
		_cr_in_arg="-"
		_cr_flags="$_cr_flags -i"
	else
		[ -f "$_cr_in" ] || {
			echo "$_cr_name: no such input: $_cr_in" >&2
			return 1
		}
		_cr_in_abs=$(container_abs "$_cr_in")
		_cr_in_dir=$(dirname -- "$_cr_in_abs")
		set -- "$@" -v "$_cr_in_dir:/in:ro"
		_cr_in_arg="/in/$(basename -- "$_cr_in_abs")"
	fi

	# --- Output --------------------------------------------------------------
	#
	# The parent is mounted, and must exist: docker creates a missing mount
	# source as a root-owned directory on the host, which is a surprising thing
	# for a PDF conversion to leave behind. The file itself will usually not
	# exist yet -- that is the normal case.
	#
	# `pdfulator dir/` writes each PDF beside its source, so input and output
	# are commonly the *same* host directory arriving at two container paths:
	# /in read-only and /out writable. That is fine and deliberately not
	# collapsed -- the two are separate in the contract, and a container that
	# saw only /in would have nowhere to write. Docker binds them
	# independently, so the read-only view does not make the writable one
	# read-only.
	if [ "$_cr_out" = "-" ]; then
		_cr_out_arg="-"
	else
		_cr_out_abs=$(container_abs "$_cr_out")
		_cr_out_dir=$(dirname -- "$_cr_out_abs")
		[ -d "$_cr_out_dir" ] || mkdir -p -- "$_cr_out_dir"
		set -- "$@" -v "$_cr_out_dir:/out"
		_cr_out_arg="/out/$(basename -- "$_cr_out_abs")"
	fi

	# --- Theme ---------------------------------------------------------------
	#
	# The built-in theme is already in the image, so mounting it would replace
	# a copy with an identical copy -- and would fail outright for a user whose
	# install directory the daemon cannot reach (a remote or rootless daemon,
	# or a home the VM does not share). Only a theme from outside is mounted.
	#
	# Compared by resolved path, since $PDFULATOR_DIR/theme and ./theme are the
	# same directory reached two ways.
	_cr_theme_arg=$_cr_builtin
	if [ -n "$_cr_theme" ] && [ -d "$_cr_theme" ]; then
		_cr_theme_abs=$(cd -- "$_cr_theme" && pwd)
		_cr_shipped=""
		if [ -d "${PDFULATOR_DIR:-}/theme" ]; then
			_cr_shipped=$(cd -- "$PDFULATOR_DIR/theme" && pwd)
		fi
		if [ "$_cr_theme_abs" != "$_cr_shipped" ]; then
			set -- "$@" -v "$_cr_theme_abs:/theme:ro"
			_cr_theme_arg=/theme
		fi
	fi

	# --- Ownership -----------------------------------------------------------
	#
	# The image runs as its own user, whose uid is very unlikely to be the
	# caller's. On Linux that leaves the PDF owned by someone else and not
	# overwritable next time; on macOS and Windows the file-sharing layer
	# remaps ownership and this is unnecessary but harmless.
	#
	# Root is left alone: `--user 0:0` would write root-owned files, which is
	# the situation being avoided.
	if [ "$(id -u)" != 0 ]; then
		_cr_flags="$_cr_flags --user $(id -u):$(id -g)"

		# A uid passed this way exists in no /etc/passwd inside the image, so
		# it has no home directory -- and Chromium insists on one. It fails in
		# a way that names neither the cause nor Chromium:
		#
		#   chrome_crashpad_handler: --database is required
		#
		# which is the crash reporter reporting that it has nowhere to write
		# its database. $HOME is what it consults, and an unset HOME leaves it
		# with nothing rather than with a default.
		#
		# /tmp is the writable directory every image is certain to have,
		# whatever uid arrives, and it is per-container so nothing outlives
		# the run.
		_cr_flags="$_cr_flags -e HOME=/tmp"
	fi

	# Verbosity travels in, so that -v on the host is -v in the container.
	if [ -n "${PDFULATOR_VERBOSE:-}" ]; then
		_cr_flags="$_cr_flags -e PDFULATOR_VERBOSE=1"
	fi
	if [ -n "${PDFULATOR_DEBUG:-}" ]; then
		_cr_flags="$_cr_flags -e PDFULATOR_DEBUG=1"
	fi

	# $_cr_flags is deliberately unquoted -- a list of separate words, not one
	# argument -- while "$@" carries the mounts, whose values may contain
	# spaces. That split is the whole reason for the two containers above.
	# shellcheck disable=SC2086
	exec "$_cr_docker" run $_cr_flags "$@" "$_cr_image" \
		"$_cr_in_arg" "$_cr_out_arg" "$_cr_theme_arg"
}
