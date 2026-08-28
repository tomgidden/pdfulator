#!/bin/sh
# pdfulator installer.
#
#   curl -fsSL https://pdfulator.app/get | sh
#
# Downloads the current release, unpacks it into $PDFULATOR_HOME, and puts the
# `pdfulator` command on your PATH. Nothing else happens without being asked:
# the runtime and the rendering browser are the wrapper's business, and it will
# explain what it needs the first time you run it.
#
# Environment:
#   PDFULATOR_HOME     where the application lives (~/.local/share/pdfulator)
#   PDFULATOR_BIN      where the command goes     (~/.local/bin)
#   PDFULATOR_VERSION  a release tag, or "latest" (default)
#   PDFULATOR_REPO     owner/repo to fetch from
#   PDFULATOR_TARBALL  install this local file instead of downloading
#   PDFULATOR_SOURCE   install straight from this checkout, no tarball at all
#   PDFULATOR_RELEASE_BASE  release URL root, if not GitHub's
#
# Options (also accepted when piped: `... | sh -s -- --install-runtime`):
#   --install-runtime   also download a private bun, if none is installed
#   --install-browser   also download a private headless browser
#   --uninstall         hand over to the installed wrapper's --uninstall
set -eu

PDFULATOR_HOME="${PDFULATOR_HOME:-$HOME/.local/share/pdfulator}"
PDFULATOR_BIN="${PDFULATOR_BIN:-$HOME/.local/bin}"
PDFULATOR_VERSION="${PDFULATOR_VERSION:-latest}"
PDFULATOR_REPO="${PDFULATOR_REPO:-tomgidden/pdfulator}"

MANIFEST="$PDFULATOR_HOME/.manifest"
STAMP="$PDFULATOR_HOME/.installed"

want_runtime=0
want_browser=0

for arg in "$@"; do
	case $arg in
		--install-runtime) want_runtime=1 ;;
		--install-browser) want_browser=1 ;;
		--uninstall)
			# The wrapper owns uninstallation -- it has the manifest logic and
			# knows what it downloaded. Support it here so a user who no longer
			# has the command on PATH can still get out via the one-liner.
			if [ -x "$PDFULATOR_BIN/pdfulator" ]; then
				exec "$PDFULATOR_BIN/pdfulator" --uninstall
			elif [ -x "$PDFULATOR_HOME/pdfulator" ]; then
				exec "$PDFULATOR_HOME/pdfulator" --uninstall
			fi
			echo "pdfulator does not appear to be installed." >&2
			echo "Looked in $PDFULATOR_BIN and $PDFULATOR_HOME." >&2
			exit 1
			;;
		-h|--help)
			# Everything from line 2 to the end of the header block, so
			# editing the header can't silently truncate the help.
			sed -n '2,/^[^#]/p' "$0" 2>/dev/null |
				sed -e '/^[^#]/d' -e 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "install.sh: unknown option: $arg" >&2
			exit 1
			;;
	esac
done


# Prerequisites

fetch_to() {  # fetch_to <url> <dest>
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	else
		wget -qO "$2" "$1"
	fi
}

fetch_stdout() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1"
	else
		wget -qO- "$1"
	fi
}

# A downloader is needed only if something is actually going to be downloaded.
# PDFULATOR_SOURCE copies a directory and PDFULATOR_TARBALL reads a local file;
# demanding curl for either turned "no network required" into a hard failure on
# a machine that had no network tools precisely because it needed none.
if [ -z "${PDFULATOR_SOURCE:-}" ] && [ -z "${PDFULATOR_TARBALL:-}" ]; then
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
		echo "pdfulator: need curl or wget to download." >&2
		exit 1
	}
fi

# Likewise tar: a source install unpacks nothing.
if [ -z "${PDFULATOR_SOURCE:-}" ]; then
	command -v tar >/dev/null 2>&1 || { echo "pdfulator: need tar." >&2; exit 1; }
fi

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}


# Work out what to download

echo "Installing pdfulator to $PDFULATOR_HOME..." >&2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# Unpack to one side, then swap into place, so an interrupted download can't
# leave a half-installed tree that looks complete.
staging="$tmp/root"
mkdir -p "$staging"

if [ -n "${PDFULATOR_SOURCE:-}" ]; then
	# A git checkout, copied rather than packed. `make install-local` builds a
	# tarball first so that what it installs is byte-for-byte what a release
	# would be; this path skips that deliberately, for the case where the
	# tarball is the thing in the way -- a bisect, a one-line change, a machine
	# with no make. It stages the same layout `make dist` does, so everything
	# downstream of here cannot tell the two apart.
	src=$PDFULATOR_SOURCE
	[ -d "$src" ] || {
		echo "pdfulator: no such directory: $src" >&2
		exit 1
	}
	[ -f "$src/pdfulator.sh" ] && [ -d "$src/lib" ] || {
		echo "pdfulator: $src is not a pdfulator checkout" >&2
		echo "(expected pdfulator.sh and lib/ in it)" >&2
		exit 1
	}
	echo "  copying from $src" >&2

	for _top in themes templates lib engines; do
		[ -d "$src/$_top" ] || continue
		cp -R "$src/$_top" "$staging/"
	done

	# node_modules is as platform-specific here as it is in a release, and the
	# wrapper reinstalls from the lockfile when it's absent. Copying a
	# checkout's tree would hand the installation the developer's arch.
	find "$staging" -name node_modules -type d -prune -exec rm -rf {} + 2>/dev/null || true

	# The wrapper is `pdfulator.sh` in a checkout and `pdfulator` once
	# installed; the tarball does this rename too, and the manifest, the PATH
	# copy and --uninstall all expect the installed name.
	cp "$src/pdfulator.sh" "$staging/pdfulator"
	cp "$src/install.sh" "$staging/install.sh"
	chmod +x "$staging/pdfulator" "$staging/install.sh"

	# What --version reports and --update compares against. A checkout has no
	# release tag of its own, so ask git the same question the GNUmakefile
	# does -- including the -dirty suffix, which is what stops --update from
	# offering to replace a work in progress with a release.
	_ver=$(cd "$src" && git describe --tags --always --dirty 2>/dev/null) || _ver=""
	[ -n "$_ver" ] || _ver="source"
	echo "$_ver" > "$staging/VERSION"
	echo "  version $_ver" >&2

elif [ -n "${PDFULATOR_TARBALL:-}" ]; then
	# Local file (a checkout's `make install-local`). Nothing came off the
	# network, so there is nothing to verify against.
	[ -f "$PDFULATOR_TARBALL" ] || {
		echo "pdfulator: no such file: $PDFULATOR_TARBALL" >&2
		exit 1
	}
	echo "  using $PDFULATOR_TARBALL" >&2
	cp "$PDFULATOR_TARBALL" "$tmp/pdfulator.tar.gz"
else
	# PDFULATOR_RELEASE_BASE exists so the download can be pointed at a mirror
	# or a local server -- which is also how the update path is tested without
	# cutting real releases.
	release_base=${PDFULATOR_RELEASE_BASE:-}
	[ -n "$release_base" ] ||
		release_base="https://github.com/$PDFULATOR_REPO/releases"

	if [ "$PDFULATOR_VERSION" = latest ]; then
		url_base="$release_base/latest/download"
	else
		url_base="$release_base/download/$PDFULATOR_VERSION"
	fi

	tarball_url="$url_base/pdfulator.tar.gz"
	checksum_url="$url_base/pdfulator.tar.gz.sha256"

	echo "  fetching $tarball_url" >&2
	fetch_to "$tarball_url" "$tmp/pdfulator.tar.gz" || {
		echo "pdfulator: download failed." >&2
		echo "Check the release exists: https://github.com/$PDFULATOR_REPO/releases" >&2
		exit 1
	}

	# Verify against the published checksum. A missing checksum file is fatal
	# rather than skippable: silently installing an unverified tarball from the
	# network is exactly what this check exists to prevent.
	echo "  verifying checksum" >&2
	if ! fetch_stdout "$checksum_url" > "$tmp/expected.sha256" 2>/dev/null; then
		echo "pdfulator: no checksum published for this release; refusing to continue." >&2
		exit 1
	fi

	expected=$(cut -d' ' -f1 < "$tmp/expected.sha256")
	actual=$(hash_file "$tmp/pdfulator.tar.gz")
	if [ "$expected" != "$actual" ]; then
		echo "pdfulator: checksum mismatch -- refusing to install." >&2
		echo "  expected $expected" >&2
		echo "  actual   $actual" >&2
		exit 1
	fi
fi


# Unpack

# PDFULATOR_SOURCE staged itself above; the other two arrive as an archive.
[ -n "${PDFULATOR_SOURCE:-}" ] || tar xzf "$tmp/pdfulator.tar.gz" -C "$staging"

# What makes an archive look right is the common layer and at least one
# engine. It used to be pdfulator.js, back when there was exactly one converter
# and it was the whole application; now the converters are engines, and which
# of them a release carries is not fixed.
[ -d "$staging/lib" ] && [ -d "$staging/engines" ] || {
	echo "pdfulator: the archive doesn't look right (no lib/ or engines/)." >&2
	exit 1
}

# Preserve anything the user added -- themes especially -- across a reinstall.
if [ -d "$PDFULATOR_HOME" ]; then
	echo "  updating existing installation" >&2
	[ -d "$PDFULATOR_HOME/themes" ] && cp -R "$PDFULATOR_HOME/themes" "$staging/" 2>/dev/null || true

	# Downloads are expensive; carry them over rather than re-fetching. The
	# pins go too: an update that silently reverted the user's runtime or
	# browser choice would look like the update broke something.
	#
	# VERSION is deliberately absent -- the incoming one is the whole point.
	# `fonts` joins them: downloaded font files are expensive to refetch and
	# have nothing to do with which version is installed. `cache` deliberately
	# does not -- staged themes are derived from the themes and engines being
	# replaced, so carrying them across an update is carrying stale output.
	keeps="bun chromium .browser .runtime fonts"

	for keep in $keeps; do
		[ -e "$PDFULATOR_HOME/$keep" ] && mv "$PDFULATOR_HOME/$keep" "$staging/" 2>/dev/null || true
	done

	# An engine's node_modules, but only where its dependencies haven't
	# changed. The wrapper installs them when the directory is absent, so
	# carrying a stale tree across a version bump would leave the engine
	# failing at import with nothing to suggest why.
	#
	# Per-engine because dependencies are: a release that changes vivlio must
	# not throw away a pandoc engine's tree, and an engine the user never
	# installed has nothing to preserve either way.
	# _nopayload/ is where an engine keeps its program, node_modules and lock
	# file included -- see lib/stage.sh. Both sides of this comparison look
	# there, so an installation from before that move simply has nothing to
	# preserve and reinstalls, which is the safe direction.
	for _eng_dir in "$staging"/engines/*; do
		[ -d "$_eng_dir" ] || continue
		_eng=$(basename "$_eng_dir")
		_old="$PDFULATOR_HOME/engines/$_eng/_nopayload"
		_eng_dir="$_eng_dir/_nopayload"
		[ -d "$_eng_dir" ] || continue
		[ -d "$_old/node_modules" ] || continue

		old_lock=""; new_lock=""
		[ -f "$_old/bun.lock" ]      && old_lock=$(hash_file "$_old/bun.lock")
		[ -f "$_eng_dir/bun.lock" ]  && new_lock=$(hash_file "$_eng_dir/bun.lock")

		if [ -n "$old_lock" ] && [ "$old_lock" = "$new_lock" ]; then
			mv "$_old/node_modules" "$_eng_dir/" 2>/dev/null || true
		else
			echo "  $_eng dependencies changed; they'll be reinstalled on first use" >&2
		fi
	done
	rm -rf "$PDFULATOR_HOME"
fi

mkdir -p "$(dirname "$PDFULATOR_HOME")"
mv "$staging" "$PDFULATOR_HOME"

# Record what we shipped, before anything generates node_modules, so the
# wrapper's --uninstall can tell our files from the user's later.
#
# themes/ IS recorded, though it once was not. The exclusion made sense while
# every theme under there was the user's; now `default` and `classic` ship in
# it, and leaving them out stranded them at uninstall -- a clean removal left
# nineteen files behind and refused to take the directory with it. Nothing is
# lost by recording them: the manifest is walked by content hash, so a shipped
# theme the user has edited is kept exactly as any other edited file is, and a
# theme they added is simply not in the list.
(
	cd "$PDFULATOR_HOME"
	find . -type f \
		! -name .manifest ! -name .installed ! -name .browser ! -name .runtime \
		! -path './node_modules/*' ! -path './bun/*' ! -path './chromium/*' |
		sed 's|^\./||' |
		while IFS= read -r rel; do
			printf '%s  %s\n' "$(hash_file "$rel")" "$rel"
		done
) > "$MANIFEST"


# Put the command on PATH

wrapper="$PDFULATOR_HOME/pdfulator"
[ -f "$wrapper" ] || { echo "pdfulator: the archive has no wrapper script." >&2; exit 1; }
chmod +x "$wrapper"

mkdir -p "$PDFULATOR_BIN"
installed_bin="$PDFULATOR_BIN/pdfulator"
if cp "$wrapper" "$installed_bin" 2>/dev/null; then
	chmod +x "$installed_bin"
else
	installed_bin=""
	echo "  (could not write to $PDFULATOR_BIN)" >&2
fi

touch "$STAMP"


# Hand over to the wrapper for anything that needs consent

# These are the wrapper's jobs; the installer only relays the request. Run
# through the installed copy so PDFULATOR_HOME resolves the same way it will
# from now on.
# PDFULATOR_POST_INSTALL tells the wrapper this is the automatic call at the end
# of an install, not the user asking to reconfigure -- so it can stay quiet when
# everything is already settled, which is the normal case after an update.
run_wrapper() {
	PDFULATOR_HOME="$PDFULATOR_HOME" PDFULATOR_BIN="$PDFULATOR_BIN" \
	PDFULATOR_POST_INSTALL=1 "$wrapper" "$@"
}

[ "$want_runtime" = 1 ] && run_wrapper --install-runtime
[ "$want_browser" = 1 ] && run_wrapper --browser install


# What now

echo "" >&2
echo "pdfulator installed." >&2
echo "  application:  $PDFULATOR_HOME" >&2
[ -n "$installed_bin" ] && echo "  command:      $installed_bin" >&2

if [ -n "$installed_bin" ]; then
	case ":${PATH:-}:" in
		*":$PDFULATOR_BIN:"*) ;;
		*)
			echo "" >&2
			echo "$PDFULATOR_BIN is not on your PATH. Add it with:" >&2
			echo "  export PATH=\"\$PATH:$PDFULATOR_BIN\"" >&2
			;;
	esac
fi

echo "" >&2
echo "Usage:" >&2
echo "  pdfulator input.md [output.pdf]    convert a file" >&2
echo "  pdfulator dir/ [outdir/]           convert a directory" >&2
echo "  pdfulator --help                   all options" >&2
echo "" >&2

# Hand over to the wrapper to settle the runtime and browser. It prompts when
# there's a terminal to prompt on, and otherwise just says what to run next --
# it knows what's already present, and it's what the user runs from now on.
run_wrapper --install >&2 || true

echo "Uninstall with:  pdfulator --uninstall" >&2
echo "" >&2
