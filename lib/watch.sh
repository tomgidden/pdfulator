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
# Which stat(1) is this? Decided once, by trying the GNU form on a file that
# certainly exists, rather than per call.
#
# A try-each-and-fall-through chain does NOT work here, and the way it fails is
# nasty: to GNU stat, `-f` is not an unknown option but "show *filesystem*
# status", so `stat -f %Fm file` succeeds and prints a block-and-inode report.
# That went into the fingerprint, free-block counts and all, and those drift on
# a live filesystem -- so watch mode saw phantom changes in a directory nobody
# had touched. On Debian in Docker this failed ~85% of runs; on macOS, where
# BSD stat is the first match anyway, never.
#
# `-c` is the discriminator because BSD stat has no such flag and genuinely
# rejects it, while GNU accepts both spellings of `-f`.
# Probed against `/` rather than $0, which is the *sourcing* script and may be
# "sh", "-", or absent depending on how the caller was invoked.
if stat -c %Y -- / >/dev/null 2>&1; then
	WATCH_STAT=gnu
else
	WATCH_STAT=bsd
fi

watch_mtime() {  # watch_mtime <file>
	case $WATCH_STAT in
		gnu) stat -c %.9Y -- "$1" 2>/dev/null || stat -c %Y -- "$1" 2>/dev/null ;;
		*)   stat -f %Fm  -- "$1" 2>/dev/null || stat -f %m  -- "$1" 2>/dev/null ;;
	esac || printf '0\n'
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
#
# PDFULATOR_WATCH overrides the choice. That exists for the tests -- which must
# be able to exercise all three branches on a machine that has none of the
# tools, and in CI, where installing them per platform to test them is a poor
# trade -- but it is also the escape hatch for a user whose fswatch misbehaves
# on some exotic filesystem. `poll` works everywhere by construction.
watch_mechanism() {
	case ${PDFULATOR_WATCH:-} in
		fswatch|inotifywait|poll) printf '%s\n' "$PDFULATOR_WATCH"; return 0 ;;
	esac

	if command -v fswatch >/dev/null 2>&1; then
		printf 'fswatch\n'
	elif command -v inotifywait >/dev/null 2>&1; then
		printf 'inotifywait\n'
	else
		printf 'poll\n'
	fi
}


# One change, as seen by an event watcher: react only if something relevant
# actually differs from the last time we looked.
#
# This is what the event branches were missing, and it is the same rule the
# poll branch gets from comparing fingerprints. Two distinct problems, one
# answer:
#
#   1. The watchers report *every* file in the directory. `watch_is_relevant`
#      was only ever consulted by watch_fingerprint, so it filtered polling
#      alone: under fswatch, a written .pdf -- or a .txt, or an editor's swap
#      file -- triggered a full re-plan.
#
#   2. Converting writes into the directory being watched, so the conversion's
#      own output is itself an event. The poll branch re-baselines afterwards;
#      an event watcher has no baseline to retake, so it would go round again.
#
# Comparing the fingerprint after each event settles both, without debouncing
# or an ignore window. A timer would have had to be longer than the slowest
# conversion (a cold container start is seconds) while still being shorter than
# a human's next keystroke -- no such interval exists. Fingerprints answer the
# question that actually matters, which is not "how long ago" but "is anything
# different now".
#
# The cost is one stat(1) per relevant file per event, which is what polling
# already pays every interval.
watch_react() {  # watch_react <dir>
	_wr_now=$(watch_fingerprint "$1")
	if [ "$_wr_now" = "${_wd_prev:-}" ]; then return 0; fi

	watch_on_change "$1"

	# Whatever the conversion just wrote is the new normal, not the next
	# change -- the same re-baselining the poll branch does, and for the same
	# reason.
	_wd_prev=$(watch_fingerprint "$1")
}


# Run an event watcher, reacting in *this* shell rather than in a subshell.
#
#   watch_via_fifo <dir> <watcher> [args...]
#
# The obvious spelling, `watcher | while read`, puts the loop body in a
# subshell, where watch_react's baseline lives and dies -- see the comment in
# watch_dir. Redirecting a named pipe into the loop instead keeps the body
# here, so the baseline survives from one event to the next.
#
# Not a process substitution (`while read; do ...; done < <(watcher)`), which
# is bash and ksh only; this file is POSIX sh, and Debian's /bin/sh is dash.
watch_via_fifo() {  # watch_via_fifo <dir> <watcher> [args...]
	_wvf_dir=$1
	shift

	_wvf_tmp=$(mktemp -d "${TMPDIR:-/tmp}/pdfulator-watch.XXXXXX") || return 1
	_wvf_fifo=$_wvf_tmp/events
	mkfifo "$_wvf_fifo" || { rm -rf "$_wvf_tmp"; return 1; }

	"$@" > "$_wvf_fifo" &
	_wvf_pid=$!

	# The watcher outlives this function otherwise: it is a background child
	# blocked on a pipe nobody is reading, and ^C reaches the shell without
	# reaching it. Interrupts included, since watch mode's normal end is ^C.
	trap 'kill "$_wvf_pid" 2>/dev/null; rm -rf "$_wvf_tmp"' EXIT INT TERM

	while read -r _; do
		watch_react "$_wvf_dir"
	done < "$_wvf_fifo"

	kill "$_wvf_pid" 2>/dev/null
	rm -rf "$_wvf_tmp"
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

	# The baseline every branch compares against. Taken before the watcher
	# starts, so a change made while it was still warming up is still seen.
	_wd_prev=$(watch_fingerprint "$_wd_dir")

	case $(watch_mechanism) in
		fswatch)
			# -o batches events into a count, so a save that fires several
			# events (editors commonly write, rename and chmod) arrives as one
			# line rather than three.
			#
			# The loop body is NOT on the right of the pipe. A `while read`
			# there runs in a subshell, and watch_react keeps its baseline in
			# _wd_prev -- which would be set in the subshell, discarded when it
			# exits, and restored to the pre-watch value on the next event. The
			# feedback loop would come straight back, and only under fswatch:
			# exactly the sort of divergence between branches that this file
			# has been bitten by before (see run_jobs, and lib/browser.sh).
			#
			# A named pipe keeps the loop in this shell. `read` blocks on it
			# just as it would on the pipe, so nothing else changes.
			watch_via_fifo "$_wd_dir" fswatch -o "$_wd_dir"
			;;

		inotifywait)
			# close_write rather than modify: an editor writing in chunks
			# fires modify repeatedly, and converting a half-written file
			# produces a broken PDF and an alarming error. moved_to catches
			# the write-to-temp-and-rename that many editors do instead.
			#
			# Same subshell problem as fswatch, same answer.
			watch_via_fifo "$_wd_dir" \
				inotifywait -q -m -e close_write,moved_to,delete "$_wd_dir"
			;;

		poll)
			# A tick is just an event with no watcher behind it, so the same
			# watch_react decides whether anything came of it.
			#
			# The rule it applies -- react only if the fingerprint moved, then
			# re-baseline -- started here, as the fix for the feedback loop
			# (d6b0369): converting writes into the very directory being
			# watched, so fingerprinting before the callback made everything
			# the conversion produced look like a fresh change. One edit
			# produced four conversions, and a callback writing a watched
			# .yaml never stopped at all.
			#
			# PDFs are not in the fingerprint (watch_is_relevant excludes
			# them), which is why it stayed hidden -- but sidecars are,
			# deliberately, and anything slow enough to overlap the next poll
			# re-triggers regardless of what it wrote.
			while :; do
				sleep "$PDFULATOR_POLL_INTERVAL"
				watch_react "$_wd_dir"
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
