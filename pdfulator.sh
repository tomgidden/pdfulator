#!/bin/sh
# pdfulator — command wrapper.
#
# Installed by install.sh as $PDFULATOR_BIN/pdfulator, alongside the
# application in $PDFULATOR_HOME. This script owns everything that outlives
# installation: finding or fetching bun, choosing the rendering browser, and
# uninstalling. Nothing heavyweight happens without being asked for.
#
#   --install                            choose a runtime and browser (asks)
#   --browser auto|find|install|<path>   choose a browser (remembered)
#   --install-runtime                    download bun if none is installed
#   --setup-status                       report what is still needed
#   --uninstall                          remove pdfulator, keeping your edits
set -e

PDFULATOR_HOME="${PDFULATOR_HOME:-$HOME/.local/share/pdfulator}"
PDFULATOR_BIN="${PDFULATOR_BIN:-$HOME/.local/bin}"

STAMP="$PDFULATOR_HOME/.installed"
MANIFEST="$PDFULATOR_HOME/.manifest"
BROWSER_CONF="$PDFULATOR_HOME/.browser"
RUNTIME_CONF="$PDFULATOR_HOME/.runtime"

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
	[ -s "$BUN_HOME/.install.log" ] && tail -5 "$BUN_HOME/.install.log" >&2
	return 1
}

# Every usable runtime on this machine, one "path<TAB>label" per line.
#
# bun is the one we manage: it's what the lockfile is for, and the only one we
# will ever download. node and deno are listed because pdfulator.js is plain
# JavaScript and runs on them unmodified -- if the user already has one, there
# is no reason to make them install anything.
list_runtimes() {
	[ -x "$BUN_PRIVATE" ] &&
		printf '%s\tbun %s (installed by pdfulator)\n' \
			"$BUN_PRIVATE" "$("$BUN_PRIVATE" --version 2>/dev/null)"

	for rt in bun node deno; do
		p=$(command -v "$rt" 2>/dev/null) || continue
		[ "$p" = "$BUN_PRIVATE" ] && continue
		# deno reports "deno x.y.z ..."; bun and node report a bare version.
		v=$("$p" --version 2>/dev/null | head -1 | sed "s/^$rt //")
		printf '%s\t%s %s\n' "$p" "$rt" "$v"
	done
}

# Run pdfulator.js under whichever runtime was chosen. `bun run` wants the
# subcommand; node and deno take the script directly (deno additionally needs
# to be told it may touch the filesystem, network and subprocesses -- it is the
# only one of the three that sandboxes by default).
run_js() {
	case $(basename "$BUN") in
		bun*)  exec_args="run $PDFULATOR_HOME/pdfulator.js" ;;
		deno*) exec_args="run -A $PDFULATOR_HOME/pdfulator.js" ;;
		*)     exec_args="$PDFULATOR_HOME/pdfulator.js" ;;
	esac
	# shellcheck disable=SC2086  # exec_args is ours, and deliberately split
	if [ "${RUN_JS_EXEC:-0}" = 1 ]; then
		PDFULATOR_HOME="$PDFULATOR_HOME" exec "$BUN" $exec_args "$@"
	fi
	PDFULATOR_HOME="$PDFULATOR_HOME" "$BUN" $exec_args "$@"
}

# Install the npm dependencies with whichever runtime is in $BUN.
#
# install.sh deliberately doesn't do this: node_modules is platform-specific and
# needs a runtime, which may only have arrived moments ago. bun installs from
# bun.lock; node and deno have no lockfile here, so they get npm's resolution of
# the same package.json -- which is why bun is the runtime we manage.
install_deps() {
	case $(basename "$BUN") in
		bun*)
			(cd "$PDFULATOR_HOME" && "$BUN" install --frozen-lockfile)
			;;
		*)
			command -v npm >/dev/null 2>&1 || {
				echo "pdfulator: npm is needed to install dependencies for $(basename "$BUN")." >&2
				echo "Run 'pdfulator --install' and choose bun instead." >&2
				return 1
			}
			(cd "$PDFULATOR_HOME" && npm install --no-audit --no-fund)
			;;
	esac
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


# The application must be where install.sh put it. If someone has copied this
# script somewhere without the rest, say so plainly rather than failing later
# with a confusing error from bun.
if [ ! -f "$PDFULATOR_HOME/pdfulator.js" ]; then
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
want_runtime=0     # --install-runtime seen
command=""         # a wrapper subcommand: uninstall | setup-status
expect=""          # non-empty while consuming a flag's value

for arg in "$@"; do
	# Value of a wrapper flag we saw last time round.
	if [ -n "$expect" ]; then
		case $expect in
			browser)     browser=$arg ;;
			passthrough) args="$args $(quote "$arg")" ;;
		esac
		expect=""
		continue
	fi

	case $arg in
		# Wrapper subcommands. Mutually exclusive; last one wins is not a
		# useful behaviour, so refuse rather than guess.
		--uninstall|--setup-status|--install)
			if [ -n "$command" ]; then
				echo "pdfulator: $arg and --$command can't be combined" >&2
				exit 1
			fi
			command=${arg#--}
			;;

		--install-runtime)  want_runtime=1 ;;

		# Wrapper flags taking a value.
		--browser|-b)       expect=browser ;;
		--browser=*)        browser=${arg#--browser=} ;;

		# Pass-through flags taking a value: copy the flag now, the value next.
		-t|--theme)         args="$args $(quote "$arg")"; expect=passthrough ;;

		*)                  args="$args $(quote "$arg")" ;;
	esac
done

if [ -n "$expect" ]; then
	case $expect in
		browser)     echo "pdfulator: --browser needs auto, find, install, or a path" >&2 ;;
		passthrough) echo "pdfulator: --theme needs a name or path" >&2 ;;
	esac
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

	# Dependencies, now that there's a runtime to install them with. This has to
	# happen before the browser question, because listing browsers means running
	# pdfulator.js, which needs its imports.
	if [ ! -d "$PDFULATOR_HOME/node_modules" ]; then
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
		browsers=$(run_js --list-browsers 2>&1 |
			awk '/^  \//{print substr($0,3)}')

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
			run_js --install-browser >&2 || exit 1
			chosen=$(run_js --list-browsers 2>&1 |
				awk '/^  \//{print substr($0,3); exit}')
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
	[ -d "$PDFULATOR_HOME/node_modules" ] ||
		echo "Dependencies will be installed on first use." >&2

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

	kept=0

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
				kept=$((kept + 1))
			fi
		done < "$MANIFEST"
	fi

	# Generated state, never user content: node_modules is reinstallable, and
	# chromium/ and bun/ are things we downloaded, so all three go
	# unconditionally. A system-wide bun is untouched -- we only ever wrote here.
	rm -rf "$PDFULATOR_HOME/node_modules" "$PDFULATOR_HOME/chromium" "$BUN_HOME"
	rm -f "$STAMP" "$MANIFEST" "$BROWSER_CONF"

	# Prune directories that are now empty. -depth so children are considered
	# before parents; a dir holding a kept or user-added file simply fails
	# rmdir and survives, which is exactly the intent.
	find "$PDFULATOR_HOME" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null || true

	# Remove the installed copy of this script, but never the one being run --
	# that could be a build tree or a download the user still wants.
	installed_bin="$PDFULATOR_BIN/pdfulator"
	self=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
	if [ -f "$installed_bin" ] && [ "$installed_bin" != "$self" ]; then
		rm -f "$installed_bin"
		echo "  removed $installed_bin" >&2
	fi

	if rmdir "$PDFULATOR_HOME" 2>/dev/null; then
		echo "Removed $PDFULATOR_HOME" >&2
	else
		echo "" >&2
		echo "Kept $PDFULATOR_HOME ($kept modified/added file(s) remain)." >&2
		echo "Remove it yourself with:  rm -rf \"$PDFULATOR_HOME\"" >&2
	fi

	if [ "$installed_bin" = "$self" ]; then
		echo "" >&2
		echo "This script is the installed copy; remove it with:" >&2
		echo "  rm \"$self\"" >&2
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

if [ -z "${BUN:-}" ]; then
	BUN=$(find_bun) || {
		if [ "$want_runtime" = 1 ]; then
			install_bun || exit 1
			BUN=$BUN_PRIVATE
		else
			bun_needed_message
			exit 1
		fi
	}
fi

# npm dependencies. install.sh deliberately doesn't run this -- node_modules is
# platform-specific and needs a runtime, which may only have arrived just now.
# It's cheap to check and only ever runs once.
#
# bun installs from bun.lock; node and deno have no such lockfile here, so they
# get npm's resolution of the same package.json. That's why bun is the runtime
# we manage and the one to prefer.
if [ ! -d "$PDFULATOR_HOME/node_modules" ]; then
	echo "Installing dependencies..." >&2
	install_deps >&2 || {
		echo "pdfulator: dependency installation failed." >&2
		exit 1
	}
fi

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
		# Detect and pin in one step: pdfulator.js reports candidates best-first,
		# so the first path it lists is the one to take.
		found=$(run_js --list-browsers 2>&1 | awk '/^  \//{print substr($0,3); exit}')
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
		run_js --list-browsers; exit $?
		;;

	install)
		# Download, then pin whatever it installed.
		run_js --install-browser >&2 || exit $?
		found=$(run_js --list-browsers 2>&1 | awk '/^  \//{print substr($0,3); exit}')
		[ -n "$found" ] || { echo "pdfulator: install succeeded but no browser found." >&2; exit 1; }
		CHROME_PATH=$found
		pin_browser "$found"
		;;

	*)
		command -v "$browser" >/dev/null 2>&1 || [ -x "$browser" ] || {
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

# --help comes from pdfulator.js, which knows nothing about the bundle, so
# append the options only the wrapper implements.
case " $* " in
	*" --help "*|*" -h "*)
		run_js "$@" || true
		echo "Bundle options:" >&2
		echo "      --install             choose a runtime and browser (asks)" >&2
		echo "  -b, --browser auto        detect a browser and remember it" >&2
		echo "      --browser find        list browsers found on this machine" >&2
		echo "      --browser install     download a private browser (~96MB)" >&2
		echo "      --browser <path>      use this browser (remembered)" >&2
		echo "      --install-runtime     download bun if it isn't installed" >&2
		echo "      --uninstall           remove pdfulator (keeps your themes)" >&2
		exit 0
		;;
esac

# A bare `--browser <path>` with nothing to convert is just configuration.
[ $# -eq 0 ] && [ -n "$browser" ] && exit 0


# Replace this shell: pdfulator.js owns the exit status and the signals.
RUN_JS_EXEC=1 run_js "$@"
