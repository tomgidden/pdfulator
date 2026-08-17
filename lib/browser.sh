# lib/browser.sh — finding Chromium.
#
# Ported from listChromiumCandidates() in the v2 pdfulator.js. It lived there
# only for convenience: it is a table of paths and a $PATH scan, which needs no
# JS runtime and no engine. Keeping it there had a concrete cost -- the wrapper
# consumed it by running the JS and *scraping its printed output* with awk, so
# the format of a human-readable list was load-bearing. This file removes that.
#
# Two reasons beyond the scrape make the shell the right home. Every
# browser-based engine needs this, so one copy serves all of them; and
# pandoc-xslt needs none of it, so a user of that engine should never pay for a
# browser search -- or for the JS runtime that used to be required to do one.
#
# The `@puppeteer/browsers` *download* stays in the vivlio engine: that is a
# real JS dependency, not a path table.
#
# Requires lib/paths.sh.
#
# The governing rule is consent: detection only ever *offers* candidates.
# Nothing here launches a browser, and nothing here pins one. Choosing is the
# user's call, made once via --browser and remembered thereafter.


# The managed browser: the only one pdfulator ever downloads, kept inside
# $PDFULATOR_HOME so uninstalling takes it away too.
: "${PDFULATOR_HOME:=$HOME/.local/share/pdfulator}"
MANAGED_BROWSER_DIR="$PDFULATOR_HOME/chromium"
MANAGED_BROWSER="chrome-headless-shell"


# Which table applies. Only the current platform's list is ever consulted, so a
# name meaning different things on different systems can't leak across.
browser_platform() {
	case $(uname -s 2>/dev/null) in
		Darwin)              printf 'darwin\n' ;;
		Linux)               printf 'linux\n' ;;
		CYGWIN*|MINGW*|MSYS*) printf 'win32\n' ;;
		*)                   printf 'unknown\n' ;;
	esac
}


# Known install locations, most-preferred first, one per line.
#
# Carried over verbatim from the JS table -- the same paths in the same order,
# because the order encodes which browser a user most likely wants rather than
# just which exists.
browser_candidate_paths() {  # browser_candidate_paths
	case $(browser_platform) in
		darwin)
			cat <<-EOF
			/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
			/Applications/Chromium.app/Contents/MacOS/Chromium
			/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary
			/Applications/Brave Browser.app/Contents/MacOS/Brave Browser
			/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge
			/Applications/Vivaldi.app/Contents/MacOS/Vivaldi
			$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
			$HOME/Applications/Chromium.app/Contents/MacOS/Chromium
			$HOME/Applications/Brave Browser.app/Contents/MacOS/Brave Browser
			$HOME/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge
			EOF
			;;

		linux)
			# Distro packages, then local/vendor tarballs, then snap, then
			# flatpak. The flatpak entries are the wrapper binaries inside the
			# runtime tree: launching those directly rather than via
			# `flatpak run` keeps puppeteer's --flags and stdio behaviour
			# intact, and the sandbox still applies.
			cat <<-EOF
			/usr/bin/chromium
			/usr/bin/chromium-browser
			/usr/bin/google-chrome
			/usr/bin/google-chrome-stable
			/usr/bin/brave-browser
			/usr/bin/microsoft-edge
			/usr/bin/microsoft-edge-stable
			/usr/bin/vivaldi-stable
			/usr/local/bin/chromium
			/usr/local/bin/google-chrome
			/opt/google/chrome/chrome
			/opt/microsoft/msedge/msedge
			/opt/brave.com/brave/brave-browser
			/snap/bin/chromium
			/snap/bin/google-chrome
			/snap/bin/brave
			/var/lib/flatpak/app/com.google.Chrome/current/active/files/chrome/chrome
			/var/lib/flatpak/app/org.chromium.Chromium/current/active/files/chromium/chromium
			/var/lib/flatpak/app/com.brave.Browser/current/active/files/brave/brave
			$HOME/.local/share/flatpak/app/com.google.Chrome/current/active/files/chrome/chrome
			$HOME/.local/share/flatpak/app/org.chromium.Chromium/current/active/files/chromium/chromium
			EOF
			;;

		win32)
			# %LOCALAPPDATA% first: per-user installs need no admin rights, so
			# they are what a desktop user most likely has. Each root is only
			# offered if the variable is actually set, since an unset one would
			# otherwise produce candidates rooted at the filesystem root.
			[ -n "${LOCALAPPDATA:-}" ] && cat <<-EOF
			$LOCALAPPDATA\\Google\\Chrome\\Application\\chrome.exe
			$LOCALAPPDATA\\Chromium\\Application\\chrome.exe
			$LOCALAPPDATA\\Microsoft\\Edge\\Application\\msedge.exe
			$LOCALAPPDATA\\BraveSoftware\\Brave-Browser\\Application\\brave.exe
			EOF
			[ -n "${PROGRAMFILES:-}" ] && cat <<-EOF
			$PROGRAMFILES\\Google\\Chrome\\Application\\chrome.exe
			$PROGRAMFILES\\Microsoft\\Edge\\Application\\msedge.exe
			$PROGRAMFILES\\BraveSoftware\\Brave-Browser\\Application\\brave.exe
			EOF
			# `${PROGRAMFILES(X86)}` is not a portable shell variable name --
			# the parentheses are not valid in an sh identifier -- so it is
			# read from the environment instead.
			_bc_x86=$(env | sed -n 's/^PROGRAMFILES(X86)=//p' | head -1)
			[ -n "$_bc_x86" ] && cat <<-EOF
			$_bc_x86\\Google\\Chrome\\Application\\chrome.exe
			$_bc_x86\\Microsoft\\Edge\\Application\\msedge.exe
			EOF
			;;
	esac
	return 0
}


# Names to look for on $PATH when no known location matched.
browser_path_names() {
	if [ "$(browser_platform)" = win32 ]; then
		printf 'chrome.exe\nmsedge.exe\nchromium.exe\n'
	else
		printf 'chromium\nchromium-browser\ngoogle-chrome\ngoogle-chrome-stable\n'
		printf 'brave-browser\nmicrosoft-edge\nvivaldi-stable\n'
	fi
}


# The browser pdfulator downloaded for itself, if there is one.
#
# The @puppeteer/browsers cache layout is
# <cacheDir>/<browser>/<platform>-<buildId>/..., with the binary one to three
# levels below the build directory depending on the platform. Newest build
# first, so an upgrade takes effect without a manual clean.
browser_find_managed() {
	_bm_root="$MANAGED_BROWSER_DIR/$MANAGED_BROWSER"
	[ -d "$_bm_root" ] || return 1

	if [ "$(browser_platform)" = win32 ]; then
		_bm_exe="$MANAGED_BROWSER.exe"
	else
		_bm_exe=$MANAGED_BROWSER
	fi

	# `sort -r` rather than `sort -Vr`: stock macOS has no `sort -V` (see the
	# portability memory), and these names sort usefully enough without it.
	for _bm_build in $(ls -1 "$_bm_root" 2>/dev/null | sort -r); do
		_bm_hit=$(find "$_bm_root/$_bm_build" -maxdepth 3 -name "$_bm_exe" \
		          -type f 2>/dev/null | head -1)
		if [ -n "$_bm_hit" ] && [ -x "$_bm_hit" ]; then
			printf '%s\n' "$_bm_hit"
			return 0
		fi
	done
	return 1
}


# Every browser we can find, best-guess first, as "path<TAB>source" lines.
#
# The source is what makes the list readable to a user choosing from it: an
# entry found on $PATH deserves more suspicion than one at a known location,
# because anything named `chromium` anywhere on the path will match. That is
# also why $PATH is searched last -- and why the same binary reached two ways
# is reported once, under the more trustworthy source.
#
# The three sources are gathered into one stream *first* and deduplicated in a
# single pass afterwards, rather than filtered as they are produced. In sh a
# `while read` on the right of a pipe runs in a subshell, so a `seen` variable
# updated inside one is discarded when it ends -- the dedup would silently do
# nothing across sources, which is exactly where duplicates arise. Keeping the
# loop out of a pipeline is what makes the accumulator survive.
browser_list() {
	_bl_all=$(browser_gather)
	_bl_seen=""
	_bl_out=""

	# A newline-delimited read, not a `for` over unquoted output: these paths
	# contain spaces ("/Applications/Google Chrome.app/...") and word-splitting
	# would shred them.
	while IFS='	' read -r _bl_p _bl_src; do
		[ -n "$_bl_p" ] || continue
		case "$_bl_seen" in
			*"	$_bl_p	"*) continue ;;
		esac
		_bl_seen="$_bl_seen	$_bl_p	"
		_bl_out="$_bl_out$_bl_p	$_bl_src
"
	done <<-EOF
	$_bl_all
	EOF

	[ -n "$_bl_out" ] && printf '%s' "$_bl_out"
	return 0
}


# The raw stream, in preference order and with duplicates still in it.
browser_gather() {
	_bg_managed=$(browser_find_managed) &&
		printf '%s\tinstalled by pdfulator\n' "$_bg_managed"

	browser_candidate_paths | while IFS= read -r _bg_p; do
		[ -n "$_bg_p" ] || continue
		[ -e "$_bg_p" ] && printf '%s\tsystem\n' "$_bg_p"
	done

	browser_path_names | while IFS= read -r _bg_n; do
		_bg_p=$(command -v "$_bg_n" 2>/dev/null) || continue
		[ -n "$_bg_p" ] && [ -x "$_bg_p" ] || continue
		printf '%s\ton PATH\n' "$_bg_p"
	done

	return 0
}

# Just the paths, for callers that only want to pick one.
browser_list_paths() {
	browser_list | cut -f1
}

# The best guess, or nothing. Used by `--browser auto`, which detects and pins
# in one step: the list is ordered by preference, so the first entry is it.
browser_best() {
	_bb=$(browser_list_paths | head -1)
	[ -n "$_bb" ] || return 1
	printf '%s\n' "$_bb"
}


# Is this a browser we can actually run? Accepts a path or a command name, the
# two things a user may pass to --browser.
#
# `-f` as well as `-x`, not `-x` alone: a directory is executable in the sense
# `-x` means (you may cd into it), so `-x` by itself accepts one. That is not
# hypothetical -- on macOS the obvious thing to type is
# `--browser /Applications/Google Chrome.app`, which is a bundle directory, and
# the binary is several levels inside it. Refusing here turns that into an
# immediate, explicable error rather than a puzzling failure at launch.
browser_is_usable() {  # browser_is_usable <path-or-name>
	[ -n "${1:-}" ] || return 1
	[ -f "$1" ] && [ -x "$1" ] && return 0
	# A bare name: resolve on $PATH, then apply the same test.
	_bu=$(command -v "$1" 2>/dev/null) || return 1
	[ -n "$_bu" ] && [ -f "$_bu" ] && [ -x "$_bu" ]
}


# The binary inside a macOS .app bundle, given the bundle.
#
# A bundle is not itself runnable, but it is the obvious thing for a Mac user
# to name, so accepting one and pointing inside is kinder than refusing. This
# is a lookup rather than a search: a bundle declares its executable in
# Contents/MacOS, named for the app, so there is one place to look and one
# answer. Falling back to the sole entry in Contents/MacOS covers the browsers
# whose binary is named differently from the bundle.
browser_resolve_bundle() {  # browser_resolve_bundle <path>
	case $1 in
		*.app|*.app/) ;;
		*) return 1 ;;
	esac

	_brb_dir=${1%/}
	_brb_name=$(basename -- "$_brb_dir" .app)

	if [ -f "$_brb_dir/Contents/MacOS/$_brb_name" ] &&
	   [ -x "$_brb_dir/Contents/MacOS/$_brb_name" ]; then
		printf '%s\n' "$_brb_dir/Contents/MacOS/$_brb_name"
		return 0
	fi

	_brb_only=$(find "$_brb_dir/Contents/MacOS" -maxdepth 1 -type f -perm -u+x \
	            2>/dev/null | head -2)
	# Only when it is unambiguous: two executables mean guessing, and guessing
	# which binary in someone's browser to launch is not this tool's business.
	if [ -n "$_brb_only" ] && [ "$(printf '%s\n' "$_brb_only" | grep -c .)" = 1 ]; then
		printf '%s\n' "$_brb_only"
		return 0
	fi

	return 1
}
