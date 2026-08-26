#!/bin/sh
# pdfulator — command wrapper.
#
# Installed by install.sh as $PDFULATOR_BIN/pdfulator, alongside the
# application in $PDFULATOR_HOME.
#
# This is the command, and it is also the common layer: it decides *what* to
# do, and an engine only converts one document. Job planning, theme
# resolution, browser discovery, watching and engine selection all live here,
# in lib/, because they are shared by every engine -- and because they were
# previously implemented three times over, in three languages, which disagreed.
#
# It also owns everything that outlives a conversion: finding or fetching bun,
# choosing the rendering browser, updating and uninstalling. Nothing heavyweight
# happens without being asked for.
#
#   -e, --engine <id>                    choose an engine (remembered)
#       --list-engines                   show what's installed
#   --install                            choose a runtime and browser (asks)
#   --browser auto|find|install|<path>   choose a browser (remembered)
#   --install-runtime                    download bun if none is installed
#   --prepare                            fetch what the chosen engine needs
#   --css <file>                         extra stylesheet, after the theme
#   --font-fallback                      standard PDF fonts if one can't be had
#   --setup-status                       report what is still needed
#   --update [--check|--yes|--force]     fetch and install a newer release
#   --version                            report the installed version
#   --uninstall                          remove pdfulator, keeping your edits
set -e

PDFULATOR_HOME="${PDFULATOR_HOME:-$HOME/.local/share/pdfulator}"
PDFULATOR_BIN="${PDFULATOR_BIN:-$HOME/.local/bin}"

# Where the library and the engines live. The same directory as the
# application, which is $PDFULATOR_HOME once installed -- but not in a
# checkout, where this script sits beside lib/ instead. Preferring the
# installed copy keeps `pdfulator` meaning the installed one even when run
# from a source tree.
# An explicit $PDFULATOR_DIR wins, which is how a checkout is tested against
# its own lib/ and engines/ without installing first.
if [ -z "${PDFULATOR_DIR:-}" ]; then
	PDFULATOR_DIR="$PDFULATOR_HOME"
	if [ ! -d "$PDFULATOR_DIR/lib" ]; then
		PDFULATOR_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
	fi
fi

# The common layer. Order matters: conf.sh and paths.sh are the foundation,
# and jobs.sh, theme.sh and fonts.sh build on them; stage.sh builds on fonts.sh
# and theme.sh in turn.
#
# Sourced rather than duplicated, and sourced *here* rather than per-engine,
# because this is the layer every engine shares -- job planning, theme
# resolution, browser discovery and watching are the wrapper's, and an engine
# only converts. See lib/jobs.sh for why: these were implemented three times
# over, in three languages, and the three disagreed.
for _lib in conf paths jobs theme template styling fonts stage browser watch engines; do
	if [ -r "$PDFULATOR_DIR/lib/$_lib.sh" ]; then
		. "$PDFULATOR_DIR/lib/$_lib.sh"
	else
		echo "pdfulator: installation is incomplete: no lib/$_lib.sh in $PDFULATOR_DIR" >&2
		echo "Reinstall with:  curl -fsSL https://pdfulator.app/get | sh" >&2
		exit 1
	fi
done

STAMP="$PDFULATOR_HOME/.installed"
MANIFEST="$PDFULATOR_HOME/.manifest"
BROWSER_CONF="$PDFULATOR_HOME/.browser"
RUNTIME_CONF="$PDFULATOR_HOME/.runtime"
VERSION_FILE="$PDFULATOR_HOME/VERSION"

# Where --update looks for what's been released. Overridable for testing and
# for anyone running their own build.
PDFULATOR_MANIFEST_URL="${PDFULATOR_MANIFEST_URL:-https://pdfulator.app/manifest}"

# Private bun, used only if the system hasn't got one.
BUN_HOME="$PDFULATOR_HOME/bun"
BUN_PRIVATE="$BUN_HOME/bin/bun"

# Oldest bun we'll accept from the system. Below this we install our own rather
# than fail obscurely somewhere inside pdfulator.js.
BUN_MIN_MAJOR=1

# Locate a usable bun, preferring one we installed (known-good) over the
# system's. Prints the path, or nothing if there isn't one.
find_bun() {
	if [ -x "$BUN_PRIVATE" ]; then
		printf '%s\n' "$BUN_PRIVATE"
		return 0
	fi

	sys=$(command -v bun 2>/dev/null) || sys=""
	if [ -n "$sys" ]; then
		major=$("$sys" --version 2>/dev/null | cut -d. -f1)
		case $major in
			''|*[!0-9]*) ;;                       # unparseable: treat as unusable
			*) [ "$major" -ge "$BUN_MIN_MAJOR" ] && { printf '%s\n' "$sys"; return 0; } ;;
		esac
	fi

	return 1
}

# Fetch bun into $BUN_HOME. Uses the official installer, which picks the right
# build for this CPU (baseline vs modern, musl vs glibc) far better than we
# could -- but confined: BUN_INSTALL puts it under our directory, and an
# unrecognised SHELL sends it down its "print the instructions" branch instead
# of appending export lines to the user's ~/.zshrc or ~/.bashrc.
install_bun() {
	echo "Downloading bun to $BUN_HOME (about 60MB)..." >&2

	fetch=""
	if command -v curl >/dev/null 2>&1; then
		fetch="curl -fsSL https://bun.sh/install"
	elif command -v wget >/dev/null 2>&1; then
		fetch="wget -qO- https://bun.sh/install"
	else
		echo "pdfulator: need curl or wget to download bun." >&2
		return 1
	fi

	# The installer wants bash and unzip; say so plainly rather than letting it
	# fail halfway through.
	for tool in bash unzip; do
		command -v "$tool" >/dev/null 2>&1 || {
			echo "pdfulator: '$tool' is required to install bun." >&2
			return 1
		}
	done

	# The installer's own closing advice ("add this to your PATH") is wrong for
	# us -- this bun is private and pdfulator calls it by absolute path -- so
	# keep its chatter out of the way unless it fails or --verbose is on.
	mkdir -p "$BUN_HOME"
	if $fetch | env BUN_INSTALL="$BUN_HOME" SHELL=/pdfulator/no-shell bash >/dev/null 2>"$BUN_HOME/.install.log"; then
		[ -x "$BUN_PRIVATE" ] || {
			echo "pdfulator: bun installer finished but no binary at $BUN_PRIVATE." >&2
			return 1
		}
		echo "bun installed (private to pdfulator; your shell config is untouched)." >&2
		return 0
	fi

	echo "pdfulator: bun download failed." >&2
	# `if`, not `[ ... ] &&`: with no log to show, a bare test here is a failing
	# command, and the `return 1` below would never be reached under set -e --
	# the caller would abort with a different status and no diagnosis.
	if [ -s "$BUN_HOME/.install.log" ]; then
		tail -5 "$BUN_HOME/.install.log" >&2
	fi
	return 1
}

# Every usable runtime on this machine, one "path<TAB>label" per line.
#
# bun is the one we manage: it's what the lockfile is for, and the only one we
# will ever download. node and deno are listed because the vivlio engine's
# main.js is plain JavaScript and runs on them unmodified -- if the user
# already has one, there is no reason to make them install anything.
#
# Written with `if` throughout, and ending in an explicit `return 0`, for the
# reason browser_gather now is: a bare `[ ... ] && ...`, or a loop whose last
# iteration ends in a false test, is a *failing command*, and under `set -e`
# that aborts the caller silently. Its one call site guards it with `|| true`,
# so this is defence rather than a fix -- but the browser listing had the same
# shape, wasn't guarded, and reported "no browsers" on a machine with two.
list_runtimes() {
	if [ -x "$BUN_PRIVATE" ]; then
		printf '%s\tbun %s (installed by pdfulator)\n' \
			"$BUN_PRIVATE" "$("$BUN_PRIVATE" --version 2>/dev/null)"
	fi

	for rt in bun node deno; do
		p=$(command -v "$rt" 2>/dev/null) || p=""
		if [ -n "$p" ] && [ "$p" != "$BUN_PRIVATE" ]; then
			# deno reports "deno x.y.z ..."; bun and node report a bare version.
			v=$("$p" --version 2>/dev/null | head -1 | sed "s/^$rt //")
			printf '%s\t%s %s\n' "$p" "$rt" "$v"
		fi
	done

	return 0
}

# (run_js is gone. There is no longer a single "the JS" to run: conversion goes
# through an engine's convert, and the one remaining JS operation -- fetching a
# browser -- is install_browser below.)

# Download a private browser, by running the selected engine's installer.
#
# This is the one browser operation still in JS: @puppeteer/browsers is a real
# dependency, unlike the path table that finding a browser needs. It therefore
# belongs to an engine, and only engines that drive a browser have one.
#
# It prints the installed path on stdout and everything else on stderr, so the
# result is read rather than scraped -- which is the whole reason the old
# `--list-browsers | awk` arrangement had to go.
install_browser() {
	_ib_engine=$(engine_resolve "${engine:-}") || return 1
	_ib_script="$PDFULATOR_DIR/engines/$_ib_engine/install-browser.js"

	[ -f "$_ib_script" ] || {
		echo "pdfulator: the $_ib_engine engine cannot download a browser." >&2
		echo "Install one system-wide, then run 'pdfulator --browser auto'." >&2
		return 1
	}

	[ -n "${BUN:-}" ] || BUN=$(find_bun) || true
	[ -n "${BUN:-}" ] || { bun_needed_message; return 1; }

	case $(basename "$BUN") in
		bun*)  PDFULATOR_HOME="$PDFULATOR_HOME" "$BUN" run "$_ib_script" ;;
		deno*) PDFULATOR_HOME="$PDFULATOR_HOME" "$BUN" run -A "$_ib_script" ;;
		*)     PDFULATOR_HOME="$PDFULATOR_HOME" "$BUN" "$_ib_script" ;;
	esac
}

# Install the npm dependencies with whichever runtime is in $BUN.
#
# install.sh deliberately doesn't do this: node_modules is platform-specific and
# needs a runtime, which may only have arrived moments ago. bun installs from
# bun.lock; node and deno have no lockfile here, so they get npm's resolution of
# the same package.json -- which is why bun is the runtime we manage.
#
# Per-engine now, and only for engines that declare needs_runtime=js. An engine
# owns its dependencies because they are what make it that engine -- the viewer
# and puppeteer-core are vivlio's, and pandoc-xslt will have none of them. A
# user who only ever runs pandoc-xslt installs nothing here.
install_deps() {
	_id_status=0
	for _id_engine in $(engines_list); do
		engine_needs_runtime "$_id_engine" || continue

		_id_dir="$PDFULATOR_DIR/engines/$_id_engine"
		[ -f "$_id_dir/package.json" ] || continue

		echo "Installing dependencies for the $_id_engine engine..." >&2
		case $(basename "$BUN") in
			bun*)
				(cd "$_id_dir" && "$BUN" install --frozen-lockfile) || _id_status=1
				;;
			*)
				command -v npm >/dev/null 2>&1 || {
					echo "pdfulator: npm is needed to install dependencies for $(basename "$BUN")." >&2
					echo "Run 'pdfulator --install' and choose bun instead." >&2
					return 1
				}
				(cd "$_id_dir" && npm install --no-audit --no-fund) || _id_status=1
				;;
		esac
	done
	return $_id_status
}

# What to say when there's no bun and we haven't been told to fetch one.
bun_needed_message() {
	cat >&2 <<EOF
pdfulator runs on bun, which isn't installed here.

Choose one, once:

  pdfulator --install-runtime      download bun into $BUN_HOME
                                   (~60MB, private to pdfulator, leaves your
                                    shell config and system alone)

Or install it yourself and re-run:

  curl -fsSL https://bun.sh/install | bash      (https://bun.sh)
EOF
}

# Hash one file, printing the bare digest. Used to tell shipped files (which
# uninstall may remove) from user-modified ones (which it must keep).
hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}


# Versions
#
# The tarball carries a VERSION file: a tag like "v2.0.0" from CI, or whatever
# `git describe` produced for a local `make dist`. Anything else -- an install
# predating the stamp, or a file we can't read -- is "unknown", which --update
# treats as "older than everything", since offering an update is the useful
# thing to do when we can't tell.
installed_version() {
	if [ -s "$VERSION_FILE" ]; then
		head -1 "$VERSION_FILE" | tr -d ' \t\r'
	else
		echo unknown
	fi
}

# A local build: `git describe` output rather than a plain tag. Updating one of
# these would silently discard whatever was being worked on, so --update stops
# unless told otherwise.
is_dev_version() {
	case $1 in
		unknown)             return 0 ;;
		*-dirty)             return 0 ;;
		# v2.0.0-3-gabc1234: a tag plus commits since. A bare tag has exactly
		# two dots and no hyphen.
		*-*)                 return 0 ;;
		v[0-9]*|[0-9]*)      return 1 ;;
		*)                   return 0 ;;
	esac
}

# Compare two dotted versions. Prints -1, 0 or 1 for a<b, a==b, a>b.
#
# Hand-rolled because `sort -V` doesn't exist on BSD sort, so it isn't available
# on macOS -- and this has to work everywhere the installer does. Leading "v" is
# stripped; non-numeric components compare as 0, which is the right answer for
# the pre-release suffixes we might grow later (v2.1.0-rc1 == v2.1.0 here, and a
# tie means "no update", which is the safe direction).
version_cmp() {  # version_cmp <a> <b>
	a=${1#v}; b=${2#v}
	while [ -n "$a" ] || [ -n "$b" ]; do
		ah=${a%%.*}; bh=${b%%.*}
		case $a in *.*) a=${a#*.} ;; *) a="" ;; esac
		case $b in *.*) b=${b#*.} ;; *) b="" ;; esac

		# Trim any -suffix, then anything non-numeric becomes 0.
		ah=${ah%%-*}; bh=${bh%%-*}
		case $ah in ''|*[!0-9]*) ah=0 ;; esac
		case $bh in ''|*[!0-9]*) bh=0 ;; esac

		if [ "$ah" -lt "$bh" ]; then echo -1; return 0; fi
		if [ "$ah" -gt "$bh" ]; then echo 1;  return 0; fi
	done
	echo 0
}


# The application must be where install.sh put it. If someone has copied this
# script somewhere without the rest, say so plainly rather than failing later
# with a confusing error from bun.
#
# engines/ is the thing to check now rather than pdfulator.js: an install with
# no engines can do nothing at all, whereas the old single script has been
# replaced by as many converters as the user chose to take.
if [ ! -d "$PDFULATOR_DIR/engines" ]; then
	echo "pdfulator: no installation found at $PDFULATOR_HOME" >&2
	echo "" >&2
	echo "Install it with:" >&2
	echo "  curl -fsSL https://pdfulator.app/get | sh" >&2
	echo "" >&2
	echo "or set PDFULATOR_HOME if it lives somewhere else." >&2
	exit 1
fi


# Argument parsing
#
# One pass, before anything else looks at "$@". Wrapper-only flags are consumed
# here and never reach pdfulator.js; everything else is passed through verbatim.
#
# Two things this has to get right, both of which the previous per-flag scans
# got wrong:
#
#   * Flags that take a value. `--theme -b` must give pdfulator.js a theme
#     called "-b", not silently hand "-b" to the wrapper. So the parser knows
#     which pass-through flags consume the following argument, and copies both
#     across without inspecting the value.
#
#   * Position. `--uninstall` and friends used to be matched as "$1" only, so
#     `pdfulator foo.md --uninstall` fell through to pdfulator.js and created a
#     file named "--uninstall". They are now recognised anywhere.

# Shell-quote one argument for the eval that reinstates "$@" below.
quote() { printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"; }

args=""            # pass-through arguments, shell-quoted
browser=""         # --browser value, if given
engine=""          # --engine value, if given
list_engines=0     # --list-engines seen
theme=""           # --theme value, if given
css=""             # --css value, if given
font_fallback=0    # --font-fallback seen
watch=0            # --watch seen
verbose=0          # --verbose seen
debug=0            # --debug seen
want_runtime=0     # --install-runtime seen
command=""         # a wrapper subcommand: uninstall | setup-status | update | ...
expect=""          # non-empty while consuming a flag's value
update_check=0     # --check: report only, exit status says whether one exists
update_yes=0       # --yes: don't prompt
update_force=0     # --force: update over a dev build

for arg in "$@"; do
	# Value of a wrapper flag we saw last time round.
	if [ -n "$expect" ]; then
		case $expect in
			browser)     browser=$arg ;;
			css)         css=$arg ;;
			engine)      engine=$arg ;;
			theme)       theme=$arg ;;
			passthrough) args="$args $(quote "$arg")" ;;
		esac
		expect=""
		continue
	fi

	case $arg in
		# Wrapper subcommands. Mutually exclusive; last one wins is not a
		# useful behaviour, so refuse rather than guess.
		--uninstall|--setup-status|--install|--update|--version|--prepare)
			if [ -n "$command" ]; then
				echo "pdfulator: $arg and --$command can't be combined" >&2
				exit 1
			fi
			command=${arg#--}
			;;

		# Modifiers for --update. Only meaningful there, and checked below, so
		# that `pdfulator --check` alone is an error rather than a no-op.
		--check)            update_check=1 ;;
		--yes|-y)           update_yes=1 ;;
		--force)            update_force=1 ;;

		--install-runtime)  want_runtime=1 ;;

		# Wrapper flags taking a value.
		--browser|-b)       expect=browser ;;
		--browser=*)        browser=${arg#--browser=} ;;

		# The engine is the wrapper's business, not the engine's: it decides
		# which one runs, so the flag never reaches one.
		--engine|-e)        expect=engine ;;
		--engine=*)         engine=${arg#--engine=} ;;
		--list-engines)     list_engines=1 ;;

		# Theme resolution is the wrapper's now (lib/theme.sh): engines are
		# handed a directory, never a name, because a container engine's
		# filesystem is not the user's and the lookup has to happen out here.
		-t|--theme)         expect=theme ;;
		--theme=*)          theme=${arg#--theme=} ;;

		# Extra CSS, applied after the whole theme cascade so it wins without
		# the user having to make a theme to change one rule.
		--css)              expect=css ;;
		--css=*)            css=${arg#--css=} ;;

		# A font that cannot be had is normally fatal, because a document
		# silently rendered in a substitute typeface is the failure this whole
		# mechanism exists to prevent. This is the way to say "render it
		# anyway" -- for an offline machine, or a CI job that only cares that
		# a PDF came out.
		--font-fallback)    font_fallback=1 ;;

		# Flags the wrapper acts on rather than forwards. Watching and
		# verbosity belong to the layer that plans jobs, not to the one that
		# converts a single document.
		-w|--watch)         watch=1 ;;
		-v|--verbose)       verbose=1 ;;
		-d|--debug)         debug=1 ;;

		*)                  args="$args $(quote "$arg")" ;;
	esac
done

if [ -n "$expect" ]; then
	case $expect in
		browser)     echo "pdfulator: --browser needs auto, find, install, or a path" >&2 ;;
		engine)      echo "pdfulator: --engine needs an engine id (see --list-engines)" >&2 ;;
		theme)       echo "pdfulator: --theme needs a name or path" >&2 ;;
		css)         echo "pdfulator: --css needs a file" >&2 ;;
		passthrough) echo "pdfulator: that flag needs a value" >&2 ;;
	esac
	exit 1
fi

# --check/--yes/--force only mean something to --update. Silently ignoring them
# elsewhere would make `pdfulator --yes doc.md` look like it did something.
if [ "$command" != update ] &&
   [ $((update_check + update_yes + update_force)) -gt 0 ]; then
	echo "pdfulator: --check, --yes and --force only apply to --update" >&2
	exit 1
fi

eval "set -- $args"


# Interactive setup
#
# `pdfulator --install` asks the questions the tool already knows the answers
# to. install.sh calls it after unpacking, and it stays available afterwards so
# choices can be changed without reinstalling.
#
# Interactivity is decided by *opening* /dev/tty, not by testing it. Piped to
# `sh`, stdin is the script, so `[ -t 0 ]` is always false; and `[ -r /dev/tty ]`
# passes even with no controlling terminal, where the write then fails. Opening
# it read-write fails cleanly in both cases, so this falls back to
# non-interactive exactly when it should.
TTY_OK=0
open_tty() {
	# Probe in a subshell first. dash (Debian's /bin/sh, and what the container
	# runs) treats a failed redirection on `exec` as fatal to the whole shell --
	# `2>/dev/null` doesn't contain it, and neither does `{ ...; }` grouping. A
	# subshell does, so the failure costs us a child process instead of the run.
	if (exec 3<>/dev/tty) 2>/dev/null; then
		exec 3<>/dev/tty
		TTY_OK=1
	fi
	# `|| true` is not needed here: the `if` consumes the test's status, so a
	# false branch can't trip set -e.
}

# Prompt on the terminal and read the reply from it, so both survive stdout
# being redirected into a PDF.
ask() {  # ask <prompt> <default>; answer in $REPLY_VALUE
	printf '%s' "$1" >&3
	IFS= read -r REPLY_VALUE <&3 || REPLY_VALUE=""
	# `if`, not `&&`: a non-empty answer makes the test false, and as the last
	# command in the function that would trip set -e and kill the script --
	# meaning any answer other than the default silently aborted setup.
	if [ -z "$REPLY_VALUE" ]; then REPLY_VALUE=$2; fi
}

if [ "$command" = "install" ]; then
	# install.sh calls this at the end of every install, including the reinstall
	# that --update performs. When both choices survived that, there is nothing
	# to ask, and prompting again (or printing "now run --install") would be
	# noise. Typing `pdfulator --install` directly still always asks, because
	# changing your mind later is the reason it stays available.
	if [ "${PDFULATOR_POST_INSTALL:-0}" = 1 ] &&
	   [ -s "$RUNTIME_CONF" ] && [ -s "$BROWSER_CONF" ]; then
		echo "" >&2
		echo "Runtime: $(cat "$RUNTIME_CONF")" >&2
		echo "Browser: $(cat "$BROWSER_CONF")" >&2
		echo "" >&2
		exit 0
	fi

	open_tty
	if [ "$TTY_OK" != 1 ]; then
		# No terminal: say what to run rather than guessing or half-configuring.
		echo "" >&2
		echo "Installed!  Now run:   pdfulator --install" >&2
		echo "" >&2
		exit 0
	fi

	echo "" >&3
	echo "pdfulator setup" >&3
	echo "" >&3

	# --- Runtime -------------------------------------------------------
	runtimes=$(list_runtimes || true)
	echo "Runtimes found:" >&3
	if [ -n "$runtimes" ]; then
		i=0
		printf '%s\n' "$runtimes" | while IFS="$(printf '\t')" read -r p label; do
			i=$((i + 1))
			printf '  %d. %-46s %s\n' "$i" "$p" "$label" >&3
		done
		i=$(printf '%s\n' "$runtimes" | wc -l | tr -d ' ')
	else
		i=0
		echo "  (none)" >&3
	fi
	echo "  0. Install a dedicated bun for pdfulator (~60MB)" >&3

	# Default to the first listed runtime, or to installing one if there are
	# none. `if` rather than `&&`, which would trip set -e when the test fails.
	if [ "$i" = 0 ]; then default_choice=0; else default_choice=1; fi
	ask "Choose [$default_choice]: " "$default_choice"

	if [ "$REPLY_VALUE" = 0 ]; then
		install_bun || exit 1
		RUNTIME=$BUN_PRIVATE
	else
		RUNTIME=$(printf '%s\n' "$runtimes" | sed -n "${REPLY_VALUE}p" | cut -f1)
		[ -n "$RUNTIME" ] || { echo "pdfulator: no such choice." >&2; exit 1; }
	fi
	printf '%s\n' "$RUNTIME" > "$RUNTIME_CONF"
	echo "Runtime: $RUNTIME" >&3

	# install_deps and run_js both read $BUN, so adopt the choice now.
	BUN=$RUNTIME

	# Dependencies, now that there's a runtime to install them with. Still
	# before the browser question, because *downloading* a browser runs the
	# engine's installer, which needs its imports. (Listing browsers no longer
	# does: that is lib/browser.sh, and needs nothing.)
	if ! engines_deps_ready; then
		echo "Installing dependencies..." >&3
		install_deps >&2 || {
			echo "pdfulator: could not install dependencies." >&2
			exit 1
		}
	fi
	echo "" >&3

	# --- Browser -------------------------------------------------------
	if [ -s "$BROWSER_CONF" ]; then
		echo "Browser: $(cat "$BROWSER_CONF")  (--browser to change)" >&3
	else
		browsers=$(browser_list_paths)

		echo "Browsers found:" >&3
		if [ -n "$browsers" ]; then
			n=0
			printf '%s\n' "$browsers" | while IFS= read -r b; do
				n=$((n + 1)); printf '  %d. %s\n' "$n" "$b" >&3
			done
			n=$(printf '%s\n' "$browsers" | wc -l | tr -d ' ')
		else
			n=0
			echo "  (none)" >&3
		fi
		echo "  0. Install chrome-headless-shell for pdfulator (~193MB)" >&3

		if [ "$n" = 0 ]; then default_choice=0; else default_choice=1; fi
		ask "Choose [$default_choice]: " "$default_choice"

		if [ "$REPLY_VALUE" = 0 ]; then
			chosen=$(install_browser) || exit 1
		else
			chosen=$(printf '%s\n' "$browsers" | sed -n "${REPLY_VALUE}p")
		fi
		[ -n "$chosen" ] || { echo "pdfulator: no such choice." >&2; exit 1; }
		printf '%s\n' "$chosen" > "$BROWSER_CONF"
		echo "Browser: $chosen" >&3
	fi

	echo "" >&3
	echo "Ready. Try:  pdfulator yourfile.md" >&3
	echo "" >&3
	exec 3>&-
	exit 0
fi


# Version

if [ "$command" = "version" ]; then
	echo "pdfulator $(installed_version)"
	exit 0
fi


# Update
#
# Deliberately not a reimplementation of install.sh: that script already knows
# how to download, verify a checksum, stage and swap while preserving the user's
# themes, browser and runtime pin. --update finds out what version exists, asks,
# and then re-runs it. The copy inside $PDFULATOR_HOME is preferred (it arrived
# checksum-verified with the rest of the tarball); older installs predate that,
# so there's a fetch fallback.
#
# Sits above the runtime gate: updating must work on an installation that has
# never had a runtime chosen -- that may be exactly why someone is updating.

if [ "$command" = "update" ]; then
	current=$(installed_version)

	fetch_stdout() {
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL "$1"
		elif command -v wget >/dev/null 2>&1; then
			wget -qO- "$1"
		else
			echo "pdfulator: need curl or wget to check for updates." >&2
			return 1
		fi
	}

	manifest=$(fetch_stdout "$PDFULATOR_MANIFEST_URL") || {
		echo "pdfulator: couldn't fetch the release list from $PDFULATOR_MANIFEST_URL" >&2
		exit 1
	}

	# One release per line: version<TAB>tarball<TAB>sha256, newest first,
	# with #-comments. Take the first non-comment line as the latest.
	latest=$(printf '%s\n' "$manifest" |
		sed -e 's/#.*//' -e '/^[[:space:]]*$/d' |
		head -1 | cut -f1)

	[ -n "$latest" ] || {
		echo "pdfulator: the release list is empty or unreadable." >&2
		exit 1
	}

	echo "Installed: $current" >&2
	echo "Latest:    $latest" >&2

	# An explicit PDFULATOR_VERSION means the user has already decided which
	# release they want -- pin or downgrade -- so skip the comparison entirely.
	if [ -n "${PDFULATOR_VERSION:-}" ] && [ "$PDFULATOR_VERSION" != latest ]; then
		target=$PDFULATOR_VERSION
		echo "Requested: $target  (PDFULATOR_VERSION)" >&2
	else
		target=$latest
		if [ "$(version_cmp "$current" "$latest")" != -1 ]; then
			# Not behind the latest release. For a dev build that's not really
			# a statement about being current -- `git describe` versions aren't
			# comparable to tags -- so say what it is rather than "up to date".
			echo "" >&2
			if is_dev_version "$current"; then
				echo "This is a local build ($current), not a release." >&2
				echo "Use --force to replace it with $latest." >&2
			else
				echo "pdfulator is up to date." >&2
			fi
			# --check is for scripts: exit 0 means "an update is available", so
			# having nothing to offer is the non-zero case.
			if [ "$update_check" = 1 ]; then exit 1; fi
			if [ "$update_force" != 1 ]; then exit 0; fi
		fi
	fi

	if [ "$update_check" = 1 ]; then
		echo "" >&2
		echo "Update available: $current -> $target" >&2
		exit 0
	fi

	# A `git describe` build that is merely *behind* the latest release reaches
	# here without having passed the check above. Replacing it would discard
	# uncommitted work, so it needs the same explicit consent -- either --force,
	# or a PDFULATOR_VERSION that names what the user wants.
	#
	# "unknown" is exempt: it means an install predating the VERSION file, not a
	# working tree, and updating it is exactly the right move.
	if [ "$current" != unknown ] && is_dev_version "$current" &&
	   [ "$update_force" != 1 ] && [ -z "${PDFULATOR_VERSION:-}" ]; then
		echo "" >&2
		echo "pdfulator: $current is a local build; refusing to overwrite it." >&2
		echo "Use --force to replace it with $target." >&2
		exit 1
	fi

	if [ "$update_yes" != 1 ]; then
		open_tty
		if [ "$TTY_OK" != 1 ]; then
			echo "" >&2
			echo "Not a terminal, so nothing has been changed. To update:" >&2
			echo "  pdfulator --update --yes" >&2
			exit 1
		fi
		echo "" >&3
		ask "Update to $target? [y/N]: " n
		exec 3>&-
		case $REPLY_VALUE in
			y|Y|yes|YES) ;;
			*) echo "Nothing changed." >&2; exit 0 ;;
		esac
	fi

	# Prefer the installer that came with this install; fall back to the
	# published one for installs predating it being shipped in the tarball.
	installer="$PDFULATOR_HOME/install.sh"
	tmp_installer=""
	if [ ! -f "$installer" ]; then
		echo "  fetching the installer" >&2
		tmp_installer=$(mktemp) || exit 1
		trap 'rm -f "$tmp_installer"' EXIT INT TERM
		fetch_stdout "https://pdfulator.app/install.sh" > "$tmp_installer" || {
			echo "pdfulator: couldn't fetch the installer." >&2
			exit 1
		}
		installer=$tmp_installer
	fi

	# install.sh preserves the browser, runtime, themes and (lockfile
	# permitting) node_modules, so there is nothing to save here. It re-runs
	# `--install` at the end, which is a no-op when both pins already exist.
	#
	# `sh "$installer"` rather than executing it: the copy unpacked from the
	# tarball may not have kept its executable bit through every tar
	# implementation, and this way it doesn't matter.
	PDFULATOR_HOME="$PDFULATOR_HOME" \
	PDFULATOR_BIN="$PDFULATOR_BIN" \
	PDFULATOR_VERSION="$target" \
	PDFULATOR_RELEASE_BASE="${PDFULATOR_RELEASE_BASE:-}" \
		sh "$installer" || {
			echo "pdfulator: update failed; the existing installation is unchanged." >&2
			exit 1
		}

	exit 0
fi


# Setup status
#
# What still needs deciding, in the user's own terms. install.sh calls this
# after unpacking so the "what now" advice comes from the thing that actually
# knows, rather than being duplicated in the installer.

if [ "$command" = "setup-status" ]; then
	need=0

	if find_bun >/dev/null 2>&1; then
		:
	else
		echo "bun is not installed. pdfulator runs on it:" >&2
		echo "  pdfulator --install-runtime            download a private copy (~60MB)" >&2
		echo "  or install it yourself: https://bun.sh" >&2
		echo "" >&2
		need=1
	fi

	if [ -s "$BROWSER_CONF" ]; then
		echo "Rendering browser: $(cat "$BROWSER_CONF")" >&2
	else
		echo "No rendering browser chosen yet. Pick one, once:" >&2
		echo "  pdfulator --browser auto               use the best one found here" >&2
		echo "  pdfulator --browser find               list what's available" >&2
		echo "  pdfulator --browser install            download a private copy (~96MB)" >&2
		echo "" >&2
		need=1
	fi

	# Not a decision the user has to make -- just something that will happen on
	# the first conversion, so it isn't a surprise when it does.
	engines_deps_ready ||
		echo "Dependencies will be installed on first use." >&2

	# Likewise for what the chosen engine fetches for itself. Worth saying
	# because it may be a large download (a container image is hundreds of
	# megabytes) and because --prepare lets it happen now, on a connection the
	# user has, rather than during the first conversion on one they haven't.
	status_engine=$(engine_resolve "" 2>/dev/null) || status_engine=""
	if [ -n "$status_engine" ] && ! engine_prepared "$status_engine"; then
		echo "The $status_engine engine will fetch what it needs on first use" >&2
		echo "  pdfulator --prepare                    do that now instead" >&2
	fi

	[ "$need" = 0 ] && echo "Ready to convert." >&2
	exit 0
fi


# Uninstall

if [ "$command" = "uninstall" ]; then
	if [ ! -f "$STAMP" ]; then
		echo "pdfulator is not installed at $PDFULATOR_HOME" >&2
		exit 1
	fi

	echo "Uninstalling pdfulator from $PDFULATOR_HOME..." >&2

	# Walk the manifest and delete only files whose contents still match what
	# we shipped. Anything edited is left in place, and its absence from the
	# delete list is what later keeps its parent directory alive.
	if [ -f "$MANIFEST" ]; then
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			want=${line%%  *}
			rel=${line#*  }
			target="$PDFULATOR_HOME/$rel"

			[ -f "$target" ] || continue

			if [ "$(hash_file "$target")" = "$want" ]; then
				rm -f "$target"
			else
				echo "  keeping modified $rel" >&2
			fi
		done < "$MANIFEST"
	fi

	# Generated state, never user content: node_modules is reinstallable, and
	# chromium/ and bun/ are things we downloaded, so all three go
	# unconditionally. A system-wide bun is untouched -- we only ever wrote here.
	rm -rf "$PDFULATOR_HOME/node_modules" "$PDFULATOR_HOME/chromium" "$BUN_HOME"
	# Engines keep their own node_modules now, so removing the top-level one
	# is no longer enough to leave a clean tree.
	rm -rf "$PDFULATOR_HOME"/engines/*/node_modules
	# Which engines have been prepared: a record of downloads, not the
	# downloads themselves, and meaningless once the engines are gone.
	rm -rf "$PDFULATOR_HOME/.prepared"
	# Staged themes are derived entirely from themes and engines, so they are
	# rebuildable; the font store is downloads, like chromium and bun. Neither
	# is anything the user put there.
	rm -rf "$PDFULATOR_HOME/cache" "$PDFULATOR_HOME/fonts"
	rm -f "$STAMP" "$MANIFEST" "$BROWSER_CONF" "$RUNTIME_CONF"

	# Prune directories that are now empty. -depth so children are considered
	# before parents; a dir holding a kept or user-added file simply fails
	# rmdir and survives, which is exactly the intent.
	find "$PDFULATOR_HOME" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null || true

	# Remove the installed command. install.sh put it there, so it's ours to
	# take away -- including when it's the copy currently running, which is the
	# usual case (`pdfulator --uninstall` off the PATH). Deleting a running
	# script is safe on Unix: the shell has already read it.
	#
	# A copy running from anywhere else -- a checkout, a build tree -- is not
	# ours and is left alone.
	installed_bin="$PDFULATOR_BIN/pdfulator"
	self=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
	if [ -f "$installed_bin" ]; then
		rm -f "$installed_bin"
		echo "  removed $installed_bin" >&2
	fi

	# Anything left that we didn't ship and the user didn't modify -- a stale
	# pin from an older version, an editor's backup file. It isn't content, so
	# it shouldn't keep the directory alive, but it isn't ours to delete
	# silently either: count it so the message below is true.
	remaining=$(find "$PDFULATOR_HOME" -mindepth 1 ! -type d 2>/dev/null | wc -l | tr -d ' ')

	if [ "$remaining" = 0 ]; then
		# Empty but for directories that survived the prune above (they can't
		# have, since prune removes empty ones -- but be explicit rather than
		# relying on that).
		rm -rf "$PDFULATOR_HOME"
		echo "Removed $PDFULATOR_HOME" >&2
	else
		echo "" >&2
		echo "Kept $PDFULATOR_HOME ($remaining file(s) remain)." >&2
		echo "Remove it yourself with:  rm -rf \"$PDFULATOR_HOME\"" >&2
	fi

	# Only worth saying when the script being run isn't the installed one --
	# that copy has just been deleted, so there's nothing left to advise.
	if [ -f "$self" ] && [ "$self" != "$installed_bin" ]; then
		echo "" >&2
		echo "(this script, $self, is not part of the installation and was left alone)" >&2
	fi

	exit 0
fi



# Runtime. A choice pinned by --install wins, but is re-checked every run: it
# can disappear under us (a system upgrade, an uninstalled package manager), and
# silently falling back would be worse than saying so.
if [ -z "${BUN:-}" ] && [ -s "$RUNTIME_CONF" ]; then
	BUN=$(cat "$RUNTIME_CONF")
	if [ ! -x "$BUN" ] && ! command -v "$BUN" >/dev/null 2>&1; then
		echo "pdfulator: the chosen runtime is gone ($BUN)." >&2
		echo "Run 'pdfulator --install' to choose another." >&2
		rm -f "$RUNTIME_CONF"
		exit 1
	fi
fi

if [ -z "${BUN:-}" ] && [ "$want_runtime" = 1 ]; then
	BUN=$(find_bun) || { install_bun || exit 1; BUN=$BUN_PRIVATE; }
fi

# Finding a runtime, and installing dependencies with it, is deferred to
# dispatch -- where the selected engine's needs_runtime is known.
#
# It used to happen unconditionally, here. That was harmless when every
# conversion ran the same JS, but now it would demand bun of a pandoc-xslt user
# who has no use for it, and install an engine's dependencies to answer
# --list-engines, which reads text files. Nothing heavyweight without being
# asked for, and nothing asked for on behalf of an engine that doesn't want it.

# --install-runtime on its own is just setup: nothing left to convert.
if [ "$want_runtime" = 1 ] && [ $# -eq 0 ]; then
	echo "Runtime ready: $BUN" >&2
	exit 0
fi


# Browser selection
#
# Nothing is ever launched without the user having chosen it. pdfulator.js does
# no detection of its own; it uses $CHROME_PATH or prints setup instructions.
# The wrapper owns the choice and pins it in .browser:
#
#   --browser auto      detect now, pin the best candidate
#   --browser find      list what's here, pin nothing
#   --browser install   download a private copy, pin it
#   --browser <path>    pin that path
#
# With no switch: use the pin if there is one, otherwise let pdfulator.js
# print its setup message.

# $browser was set by the parser above; "$@" already has the flag removed.

# Write the pin and report it. Shared by every branch that settles on a path.
pin_browser() {
	printf '%s\n' "$1" > "$BROWSER_CONF"
	echo "Browser set to $1" >&2
	echo "(remembered; --browser again to change)" >&2
}

case $browser in
	'')
		# No switch: use the pin if we have one.
		if [ -z "${CHROME_PATH:-}" ] && [ -f "$BROWSER_CONF" ]; then
			CHROME_PATH=$(cat "$BROWSER_CONF")
			# A pinned browser that has since been removed must not be fatal,
			# but nor should we silently pick another -- drop the stale pin and
			# let pdfulator.js ask again.
			if [ ! -x "$CHROME_PATH" ] && ! command -v "$CHROME_PATH" >/dev/null 2>&1; then
				echo "pdfulator: the chosen browser is gone ($CHROME_PATH)." >&2
				echo "Choose another with --browser auto, find, install, or a path." >&2
				rm -f "$BROWSER_CONF"
				exit 1
			fi
		fi
		;;

	auto)
		# Detect and pin in one step. The list is in preference order, so the
		# first entry is the one to take.
		found=$(browser_best) || found=""
		if [ -z "$found" ]; then
			echo "pdfulator: no browser found to pin." >&2
			echo "Try --browser install, or install one system-wide." >&2
			exit 1
		fi
		CHROME_PATH=$found
		pin_browser "$found"
		;;

	find)
		# Show everything and pin nothing -- the user picks.
		#
		# The source column is why this is worth printing rather than just
		# listing paths: an entry found on $PATH deserves more suspicion than
		# one at a known location, since anything named `chromium` matches.
		if [ -z "$(browser_list)" ]; then
			echo "No Chromium-family browsers found." >&2
			echo "Try --browser install to fetch a private one." >&2
			exit 1
		fi
		browser_list | while IFS='	' read -r p src; do
			printf '  %s\n      (%s)\n' "$p" "$src"
		done
		exit 0
		;;

	install)
		# Download, then pin what it installed -- read from its stdout rather
		# than found by searching afterwards.
		found=$(install_browser) || exit $?
		[ -n "$found" ] || { echo "pdfulator: install succeeded but no browser found." >&2; exit 1; }
		CHROME_PATH=$found
		pin_browser "$found"
		;;

	*)
		# A .app bundle is the obvious thing to name on macOS, and is not
		# itself runnable, so it resolves to the binary inside.
		if resolved=$(browser_resolve_bundle "$browser" 2>/dev/null); then
			browser=$resolved
		fi
		browser_is_usable "$browser" || {
			echo "pdfulator: not an executable browser: $browser" >&2
			exit 1
		}
		CHROME_PATH=$browser
		pin_browser "$browser"
		;;
esac
[ -n "${CHROME_PATH:-}" ] && export CHROME_PATH

# pdfulator.js keeps a --install-browser download here, so it must agree with
# the wrapper on the location even when the caller never set it.
export PDFULATOR_HOME

# Lets pdfulator.js advise --browser (which only exists out here) rather than
# CHROME_PATH when it needs to explain how to choose a browser.
PDFULATOR_BUNDLED=1
export PDFULATOR_BUNDLED

# ("$@" was already reinstated by the parser near the top.)

# Help is the wrapper's now. It used to come from pdfulator.js with the
# bundle's own options appended, which meant the two halves of one help text
# were written in two languages and could disagree -- and once engines exist
# there is no single "the JS" to ask.
case " $* " in
	*" --help "*|*" -h "*)
		cat >&2 <<'EOF'
pdfulator — Markdown to PDF

Usage:
  pdfulator [options] input.md [output.pdf]   convert one file
  pdfulator [options] dir/ [outdir/]          convert every *.md in a directory
  pdfulator [options] -                       stdin to stdout

Options:
  -t, --theme <name|path>   theme to use
      --css <file>          extra stylesheet, applied after the theme
      --font-fallback       use standard PDF fonts when a font can't be had
  -e, --engine <id>         engine to use (remembered)
      --list-engines        show the installed engines
  -w, --watch               convert, then again whenever a source changes
  -v, --verbose             say what is happening
  -d, --debug               keep intermediate files
  -h, --help                this

Setup:
      --install             choose a runtime and browser (asks)
  -b, --browser auto        detect a browser and remember it
      --browser find        list browsers found on this machine
      --browser install     download a private browser (~193MB)
      --browser <path>      use this browser (remembered)
      --install-runtime     download bun if it isn't installed
      --prepare             fetch what the chosen engine needs, now
      --setup-status        report what is still needed
      --update              install a newer release, if there is one
      --version             report the installed version
      --uninstall           remove pdfulator (keeps your themes)
EOF
		exit 0
		;;
esac

if [ "$list_engines" = 1 ]; then
	engines_describe
	exit 0
fi

# A bare `--browser <path>` or `--engine <id>` with nothing to convert is just
# configuration. --prepare has no arguments either, but it is not configuration
# -- it has work to do below, so it must not be caught here.
if [ "$command" != "prepare" ]; then
	[ $# -eq 0 ] && { [ -n "$browser" ] || [ -n "$engine" ]; } && exit 0
fi


# --- Dispatch ----------------------------------------------------------------
#
# The shape this whole refactor was for: plan the jobs, then hand each one to
# an engine. Everything above settled *what* to do; the engine only converts.
#
# --prepare runs this same path and stops before the planning: fetching an
# engine's dependencies needs the runtime, browser and daemon settled exactly
# as a conversion does, and a separate handler would be a second copy of the
# block below, free to drift from it.

ENGINE=$(engine_resolve "$engine") || exit 1
[ -n "$engine" ] && { engine_pin "$engine" || exit 1; }
engine_warn_deprecated "$ENGINE"

THEME_SRC=$(theme_resolve "$theme") || exit 1
if [ "$verbose" = 1 ]; then echo "Theme: $THEME_SRC" >&2; fi

# What the engine actually receives is built here, not handed over as the user
# named it: the theme's inheritance chain is walked, the CSS concatenated, the
# fonts acquired, and the engine-specific configuration generated. The engine
# then reads files out of one directory and needs to know nothing about any of
# it -- which is what lets one theme serve a bundled engine, a container (mount
# the directory) and eventually a remote one (send it).
#
# Cached under $PDFULATOR_HOME/cache and keyed by content, so a directory job
# or a watch session stages once and converts many times.
# `if`, not `[ ... ] && ...`: under set -e a bare test that fails is a failing
# command, and not passing --font-fallback is the common case. Three bugs in
# lib/browser.sh were exactly this shape (daf9507).
if [ "$font_fallback" = 1 ]; then
	export PDFULATOR_FONT_FALLBACK=1
fi

STYLER=$(engine_get "$ENGINE" styler)

# Where the fonts will be when the engine runs, which is not where they are
# now: a container sees the staged directory at its mount point. Only the
# wrapper knows both, which is why the path is passed in rather than assumed.
if engine_needs_docker "$ENGINE"; then
	FONT_BASE=/theme/fonts
else
	FONT_BASE=fonts
fi

THEME_DIR=$(stage_dir "$THEME_SRC" "$ENGINE" "$STYLER" "$FONT_BASE" "$css") \
	|| exit 1
if [ "$verbose" = 1 ]; then echo "Staged: $THEME_DIR" >&2; fi

# Only what this engine actually declares. A pandoc-xslt user never meets bun,
# and never pays for a browser search -- which is the point of putting the
# requirements in engine.conf rather than assuming every engine is vivlio.
if engine_needs_runtime "$ENGINE"; then
	[ -n "${BUN:-}" ] || BUN=$(find_bun) || true
	[ -n "${BUN:-}" ] || { bun_needed_message; exit 1; }
	PDFULATOR_RUNTIME=$BUN
	export PDFULATOR_RUNTIME
	[ "$verbose" = 1 ] && echo "Runtime: $PDFULATOR_RUNTIME" >&2

	# The engine's dependencies, now that there is a runtime to install them
	# with. install.sh deliberately doesn't: node_modules is platform-specific
	# and needs a runtime, which may only have arrived moments ago.
	if ! engines_deps_ready; then
		echo "Installing dependencies..." >&2
		install_deps >&2 || {
			echo "pdfulator: dependency installation failed." >&2
			exit 1
		}
	fi
fi

if engine_needs_browser "$ENGINE" && [ -z "${CHROME_PATH:-}" ]; then
	echo "pdfulator: no browser chosen yet." >&2
	echo "Run 'pdfulator --browser auto' to use one you already have," >&2
	echo "or 'pdfulator --browser install' to fetch a private one." >&2
	exit 1
fi

# Docker, for the container engines. Checked here rather than left to the
# engine so the message names the alternative: a user who picked
# vivlio-docker on a machine without a daemon wants to be told that the
# bundled engine is right there, not to read a docker error.
#
# Only that the client exists and the daemon answers -- `docker info` rather
# than `command -v docker`, because Docker Desktop installs a client that is
# present and useless while the VM is stopped, and "cannot connect to the
# Docker daemon" mid-conversion is a worse place to find that out.
if engine_needs_docker "$ENGINE"; then
	DOCKER_CMD=${PDFULATOR_DOCKER:-docker}
	if ! command -v "$DOCKER_CMD" >/dev/null 2>&1; then
		echo "pdfulator: the $ENGINE engine needs Docker, which isn't installed." >&2
		echo "Install Docker, or use the bundled engine: pdfulator --engine vivlio" >&2
		exit 1
	fi
	if ! "$DOCKER_CMD" info >/dev/null 2>&1; then
		echo "pdfulator: Docker is installed but not responding." >&2
		echo "Start Docker and try again, or use: pdfulator --engine vivlio" >&2
		exit 1
	fi
	export PDFULATOR_DOCKER="$DOCKER_CMD"

	# The image itself, before the first conversion rather than during it.
	# lib/container.sh owns this because it owns the image= lookup, and it is
	# the wrapper that calls it because every container engine wants the same
	# thing -- the same rule that keeps the runtime and the browser out here.
	#
	# $PDFULATOR_NO_PREPARE suppresses it, except when the user asked for a
	# preparation outright: the variable exists so tests and CI don't reach the
	# network by accident, and `--prepare` is not an accident.
	if [ -z "${PDFULATOR_NO_PREPARE:-}" ] || [ "$command" = "prepare" ]; then
		. "$PDFULATOR_DIR/lib/container.sh"
		container_pull "$PDFULATOR_DIR/engines/$ENGINE" "$ENGINE" || exit 1
	fi
fi

# Whatever else this engine needs that no other engine would share: its own
# converter, its own jar, its own endpoint. Once per version, after the shared
# resources above are settled, since a `prepare` may well need them.
#
# `--prepare` forces it, ignoring the stamp: that is the flag's entire purpose,
# for a user about to go offline or one retrying a download that died halfway.
if [ "$command" = "prepare" ]; then
	engine_prepare "$ENGINE" force || exit 1
	echo "The $ENGINE engine is ready." >&2
	exit 0
fi

engine_prepare "$ENGINE" || exit 1

PDFULATOR_VERBOSE=$([ "$verbose" = 1 ] && echo 1 || echo "")
PDFULATOR_DEBUG=$([ "$debug" = 1 ] && echo 1 || echo "")
export PDFULATOR_VERBOSE PDFULATOR_DEBUG PDFULATOR_DIR

# Plan, then convert. Reinstated "$@" holds only the positional arguments by
# now, every flag having been consumed above.
run_jobs() {
	jobs_plan "$@" || return 1

	_rj_status=0
	_rj_list=$(jobs_each)
	[ -n "$_rj_list" ] || return 0

	# A `while read` on the right of a pipe runs in a subshell, so a failure
	# count set inside one is lost -- the same trap lib/browser.sh hit. A
	# here-document keeps the loop in this shell, which is what lets one
	# failed document set the exit status without stopping the others.
	while IFS='	' read -r _rj_in _rj_out; do
		[ -n "$_rj_in" ] || continue
		if [ "$verbose" = 1 ]; then echo "Converting $_rj_in" >&2; fi
		engine_convert "$ENGINE" "$_rj_in" "$_rj_out" "$THEME_DIR" || _rj_status=1
	done <<-EOF
	$_rj_list
	EOF

	return $_rj_status
}

# stdin is a single job that no planning applies to: there is no file to
# classify, no directory to scan and nothing to refuse to overwrite.
#
# Position matters, and an earlier version searched the whole argument list for
# a bare "-" instead. That made `pdfulator doc.md -` -- a file to stdout, the
# documented way to pipe one document -- read stdin and ignore doc.md, so it
# hung on a terminal and reported "empty input on stdin" in a pipeline. The
# input is $1 and the output is $2; a "-" in either place means that stream,
# and only there.
#
# No arguments at all is not a stream either: bare `pdfulator` converts the
# current directory, so the input defaults to empty rather than to "-" -- the
# latter made it read stdin, hanging on a terminal and converting nothing in a
# script.
_in=${1:-}
_out=${2:-}

if [ "$_in" = "-" ]; then
	# Nothing but "-" (and optionally an output) can follow: there is one
	# document on stdin, so a second argument naming another input is a
	# mistake worth reporting rather than silently dropping.
	engine_convert "$ENGINE" - "${_out:--}" "$THEME_DIR"
	exit $?
fi

# A file (or directory) to stdout. Planning still applies to the input side --
# it must exist and be something convertible -- but there is no output path to
# classify, and a directory cannot be written to one stream.
if [ "$_out" = "-" ]; then
	if [ -d "$_in" ]; then
		echo "pdfulator: $_in is a directory; only one document can go to stdout." >&2
		exit 1
	fi
	if [ ! -f "$_in" ]; then
		echo "pdfulator: no such file: $_in" >&2
		exit 1
	fi
	engine_convert "$ENGINE" "$_in" - "$THEME_DIR"
	exit $?
fi

if [ "$watch" = 1 ]; then
	# Watch is directory-only: watching one file and rewriting one PDF is what
	# `--watch dir/` already does for a directory of one.
	_w_dir=${1:-$PWD}
	[ -d "$_w_dir" ] || {
		echo "pdfulator: --watch needs a directory, not $_w_dir" >&2
		exit 1
	}

	watch_on_change() { run_jobs "$@" || true; }

	run_jobs "$@" || true
	echo "Watching $_w_dir for changes... (^C to stop)" >&2
	watch_dir "$_w_dir"
	exit 0
fi

run_jobs "$@"
