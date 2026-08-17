# lib/watch.sh — watch mode.
#
# Convert once, then again whenever a source changes, until interrupted.
#
# Ported from watchDir() in the v2 pdfulator.js, which used fs.watch. That was
# free there because a JS runtime was always present; here it is not, and it
# must not be -- a pandoc-xslt user has no runtime, and watching a directory is
# not a reason to acquire one. So this is shell, and it takes whichever of
# three mechanisms the machine has.
#
# Requires lib/paths.sh and lib/jobs.sh.
#
# The three, in order of preference:
#
#   fswatch       the usual answer on macOS, where inotify does not exist
#   inotifywait   the usual answer on Linux (inotify-tools)
#   polling       everywhere else, including a bare container, which is
#                 exactly where the other two are least likely to be installed
#
# The fallback is not a token gesture: `docker run` images ship neither
# watcher, and an installed-by-tarball user on a machine without Homebrew or
# apt has neither either. Polling has to actually work.


# How often to look, in seconds, when polling. A second is comfortably below
# the time a conversion takes, so the limit on responsiveness is the renderer
# rather than the poll; going lower would spend CPU to no visible effect.
#
# A whole number by default because fractional sleep, while accepted by macOS
# and GNU coreutils, is not POSIX and some sh builds reject it outright. The
# tests set a fraction deliberately, and check here that it is usable before
# relying on it.
: "${PDFULATOR_POLL_INTERVAL:=1}"

# Checked with a zero-length sleep of the same *shape*: `sleep 0.0` is accepted
# exactly where `sleep 0.2` is, and returns immediately, so sourcing this file
# costs nothing. Sleeping the real interval here would delay every run by it.
case $PDFULATOR_POLL_INTERVAL in
	*.*) sleep 0.0 2>/dev/null || PDFULATOR_POLL_INTERVAL=1 ;;
esac


# What counts as a change worth reacting to.
#
# Sidecars as well as markdown: a .yaml beside a document supplies its title
# and authors, so editing one changes the output while leaving the markdown
# untouched. The v2 code watched for both and then filtered the callback down
# to markdown alone, which meant sidecar edits woke the watcher and were then
# ignored -- a bug that reads as "watch mode doesn't notice my metadata".
watch_is_relevant() {  # watch_is_relevant <path>
	case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
		*.md|*.markdown|*.yaml|*.yml) return 0 ;;
		*)                            return 1 ;;
	esac
}


# A cheap fingerprint of everything relevant in a directory: name, size and
# modification time per file, one line each.
#
# Timestamps come from stat(1), whose flags differ between BSD and GNU -- `-f
# %m` against `-c %Y` -- so both are tried. The obvious alternative, parsing
# `ls -l`, does not work: its time column is minute-resolution once, and shows
# a *year* instead of a time for anything over six months old. A one-character
# edit that leaves the size unchanged is then invisible for the rest of the
# minute, which is precisely the edit watch mode exists to catch. That bug was
# in the first version of this file and the fingerprint tests found it.
#
# Deletions and additions are caught as well as edits, since they change the
# line count -- which matters, as removing a source should stop it being
# rebuilt from a stale copy.
# Sub-second where the platform offers it -- `%Fm` on BSD, `%.9Y` on GNU --
# falling back to whole seconds.
#
# The precision matters more than it looks. Editors save fast and files are
# small, so a one-character edit that leaves the size unchanged commonly lands
# in the same *second* as the previous one; at whole-second resolution the
# fingerprint is then identical and the change is missed until something else
# happens. Sub-second reduces that window to something no human typing can hit.
#
# A residual race remains at any precision: two writes within one tick are one
# event. Sub-second makes it negligible rather than routine, and the watchers
# proper (fswatch, inotifywait) do not have it at all -- which is why they are
# preferred when present.
watch_mtime() {  # watch_mtime <file>
	stat -f %Fm -- "$1" 2>/dev/null && return 0
	stat -c %.9Y -- "$1" 2>/dev/null && return 0
	stat -f %m  -- "$1" 2>/dev/null && return 0
	stat -c %Y  -- "$1" 2>/dev/null && return 0
	printf '0\n'
}

watch_fingerprint() {  # watch_fingerprint <dir>
	for _wf in "$1"/*; do
		[ -f "$_wf" ] || continue
		watch_is_relevant "$_wf" || continue
		printf '%s %s %s\n' "$_wf" "$(wc -c < "$_wf" | tr -d ' ')" \
		       "$(watch_mtime "$_wf")"
	done
}


# Which watcher to use. Split out so the tests can see the choice being made
# without having to install anything.
watch_mechanism() {
	if command -v fswatch >/dev/null 2>&1; then
		printf 'fswatch\n'
	elif command -v inotifywait >/dev/null 2>&1; then
		printf 'inotifywait\n'
	else
		printf 'poll\n'
	fi
}


# Watch a directory, running `watch_on_change <dir>` whenever something in it
# changes. Never returns; the user interrupts it.
#
# The callback is given the directory rather than the changed file, and
# re-plans from scratch. That is deliberate: the alternative is for watch mode
# to have its own idea of what a change implies, which is how v1's entrypoint
# came to disagree with the rest of the tool. Re-planning means watch mode and
# a plain run cannot diverge -- and the up-to-date check in job planning is
# what keeps it cheap, since unchanged documents are skipped anyway.
watch_dir() {  # watch_dir <dir>
	_wd_dir=$1

	case $(watch_mechanism) in
		fswatch)
			# -o batches events into a count, so a save that fires several
			# events (editors commonly write, rename and chmod) runs one
			# conversion rather than three.
			fswatch -o "$_wd_dir" | while read -r _; do
				watch_on_change "$_wd_dir"
			done
			;;

		inotifywait)
			# close_write rather than modify: an editor writing in chunks
			# fires modify repeatedly, and converting a half-written file
			# produces a broken PDF and an alarming error. moved_to catches
			# the write-to-temp-and-rename that many editors do instead.
			inotifywait -q -m -e close_write,moved_to,delete "$_wd_dir" |
				while read -r _; do
					watch_on_change "$_wd_dir"
				done
			;;

		poll)
			_wd_prev=$(watch_fingerprint "$_wd_dir")
			while :; do
				sleep "$PDFULATOR_POLL_INTERVAL"
				_wd_now=$(watch_fingerprint "$_wd_dir")
				if [ "$_wd_now" != "$_wd_prev" ]; then
					_wd_prev=$_wd_now
					watch_on_change "$_wd_dir"
				fi
			done
			;;
	esac
}


# What to do on a change. The caller replaces this; the default exists so that
# sourcing this file and calling watch_dir does something explicable rather
# than failing with "command not found".
watch_on_change() {  # watch_on_change <dir>
	printf 'changed: %s\n' "$1" >&2
}
