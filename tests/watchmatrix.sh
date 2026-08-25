#!/bin/sh
# Watch mode.
#
# Testing a loop that never returns needs care: every case here runs the
# watcher in the background, gives it a bounded time to react, and kills it.
# Nothing waits indefinitely, so a broken watcher fails the suite rather than
# hanging it -- which matters more than usual, since a hung test in CI costs
# the whole job's timeout.
#
# The poll fallback is what gets exercised in detail. That is the right
# emphasis rather than an accident of what is installed: fswatch and
# inotifywait are absent from Docker images and from any machine without
# Homebrew or apt, so polling is what most users of a bare install will get.
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "$LIB/paths.sh"
. "$LIB/watch.sh"

# Per-run directory, and every watcher stopped on the way out.
#
# A fixed path is fine for the other matrices, which only touch the filesystem
# synchronously. This one leaves background watchers running, so two concurrent
# runs -- or one run after another that died before its cleanup -- share a
# fixture and a log, and each sees the other's conversions as its own. That
# looks exactly like the flakiness it is not: "quiet directory stays quiet"
# reporting three hits, in a directory nothing touched.
BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-watchmatrix.$$
FAIL=0

# Whatever happens -- pass, fail, or ^C -- take the watchers down and the
# directory with them. A leaked watcher polling a deleted directory is not
# harmful, but it is confusing to find later.
#
# PIDs are accumulated by hand rather than taken from `jobs -p`, which is not
# dependable in a POSIX sh trap: job control is off in non-interactive shells,
# so the job table may be empty by the time the trap runs.
WATCHERS=""
watcher_stop_all() {
	for _w in $WATCHERS; do
		kill "$_w" 2>/dev/null
		# The mechanisms that run as a pipeline (fswatch, inotifywait, and the
		# subshell reading from them) survive their parent, so the children go
		# too.
		pkill -P "$_w" 2>/dev/null
	done
	WATCHERS=""
}
trap 'watcher_stop_all; rm -rf "$BASE"' EXIT INT TERM

# --- Stand-in watchers -------------------------------------------------------
#
# Installed here, before the first case, rather than beside the EVENT WATCHERS
# section that is mostly about them.
#
# They have to be on PATH before *any* section that forces a mechanism with
# $PDFULATOR_WATCH, and NON-REPRODUCIBLE OUTPUT does exactly that several
# hundred lines earlier. With the stubs installed later, that section selected
# fswatch and then found whatever fswatch the machine happened to have -- so
# it passed on a laptop with brew's fswatch installed and reported zero
# conversions on one without, which is a test that measures the machine rather
# than the code. It was installed on the machine these cases were written on,
# and gone from it a fortnight later.
#
# The stubs live *beside* $BASE rather than inside it: fixture() does
# `rm -rf "$BASE"`, so a $BASE/stubs is deleted before the first case that
# needs it. That failure is quiet and misleading -- PATH then names a missing
# directory, the real tool is absent too, and every positive case reports "no
# reaction" while every negative case passes for having run nothing at all.
STUBS=$BASE.stubs
mkdir -p "$STUBS"

# Both stubs poll internally and print a line per change, which is what the
# real tools do from the kernel. The point is not how they detect a change but
# that watch_dir reacts correctly to the events, including events it should
# ignore.
cat > "$STUBS/fswatch" <<'STUB'
#!/bin/sh
# Stand-in for `fswatch -o <dir>`: a count per batch of changes.
dir=""
for a in "$@"; do case $a in -*) ;; *) dir=$a ;; esac; done
prev=$(ls -a "$dir" 2>/dev/null; cat "$dir"/* 2>/dev/null)
while :; do
	sleep 0.1
	now=$(ls -a "$dir" 2>/dev/null; cat "$dir"/* 2>/dev/null)
	if [ "$now" != "$prev" ]; then printf '1\n'; prev=$now; fi
done
STUB

cat > "$STUBS/inotifywait" <<'STUB'
#!/bin/sh
# Stand-in for `inotifywait -q -m -e ... <dir>`: "<dir> <EVENT> <file>".
dir=""
for a in "$@"; do case $a in -*) ;; *) dir=$a ;; esac; done
prev=$(ls -a "$dir" 2>/dev/null; cat "$dir"/* 2>/dev/null)
while :; do
	sleep 0.1
	now=$(ls -a "$dir" 2>/dev/null; cat "$dir"/* 2>/dev/null)
	if [ "$now" != "$prev" ]; then printf '%s/ CLOSE_WRITE,CLOSE x\n' "$dir"; prev=$now; fi
done
STUB

chmod +x "$STUBS/fswatch" "$STUBS/inotifywait"
PATH=$STUBS:$PATH
export PATH

# Re-set now that $STUBS exists, so the stubs are cleaned up too.
trap 'watcher_stop_all; rm -rf "$BASE" "$STUBS"' EXIT INT TERM

# Poll fast, so the tests take a second rather than ten.
PDFULATOR_POLL_INTERVAL=0.2

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

fixture() {
	rm -rf "$BASE"; mkdir -p "$BASE/src"; cd "$BASE" || exit 1
	printf '# One\n' > src/a.md
	printf 'title: Sidecar\n' > src/a.yaml
	printf 'not a document\n' > src/notes.txt
}

# Run the watcher against $BASE/src for at most <timeout> seconds, performing
# <action> shortly after it starts. Every conversion appends to $BASE/log, so
# the log is the record of what the watcher reacted to.
#
# This test was flaky for two reasons, and neither was the one it looked like.
# Recorded because the obvious diagnosis -- "a background test, therefore a
# timing race, therefore lengthen the sleep" -- was wrong twice, and lengthening
# the sleep hid the second cause while making the first worse:
#
#   1. watch_dir took its baseline *before* running the callback, so everything
#      a conversion wrote looked like a fresh change. One edit produced four
#      conversions. Fixed in lib/watch.sh; pinned by CONVERSION FEEDBACK below.
#
#   2. The fixture path was fixed, so two runs of this file shared a directory
#      and a log -- and this file leaves watchers running. The symptom was a
#      *quiet* directory reporting three conversions, which reads as a bug in
#      the watcher rather than as another copy of the test. Fixed by the $$ in
#      $BASE and the EXIT trap above.
watch_run() {  # watch_run <timeout> <action>
	: > "$BASE/log"
	watch_on_change() { printf 'convert %s\n' "$1" >> "$BASE/log"; }

	watch_dir "$BASE/src" >/dev/null 2>&1 &
	_wr_pid=$!
	WATCHERS="$WATCHERS $_wr_pid"

	# A quiet interval for the watcher to take its baseline before the case
	# acts: a change made before the first fingerprint exists is not one the
	# watcher can see.
	#
	# Several polls' worth, not a guessed wall-clock figure, so the wait scales
	# with the interval the test is actually running at. Two earlier attempts
	# used a fixed sleep and a warmup file respectively; both were flaky,
	# because the real cause was not timing at all but the feedback loop in
	# watch_dir that CONVERSION FEEDBACK below now pins.
	sleep 1

	eval "$2"
	sleep "$1"

	kill "$_wr_pid" 2>/dev/null
	wait "$_wr_pid" 2>/dev/null
	# The pipeline's children (fswatch, inotifywait, or the subshell reading
	# from them) outlive the shell that started them, so killing the job alone
	# leaves them running. In the poll case there is nothing else to clean up.
	pkill -P "$_wr_pid" 2>/dev/null
	:
}

# grep -c exits 1 when it matches nothing, so `|| echo 0` would print a count
# *and* a zero. Counting lines of the filtered output sidesteps that.
hits() { grep 'convert' "$BASE/log" 2>/dev/null | wc -l | tr -d ' '; }


echo "============ MECHANISM ============"
# Whichever is available is the one used; the point of the check is that the
# choice is made and named, so a machine reports what it will actually do.
M=$(watch_mechanism)
echo "mechanism here: $M"
case $M in
	fswatch|inotifywait|poll) echo "ok    a known mechanism was chosen" ;;
	*) echo "FAIL  unknown mechanism: $M"; FAIL=1 ;;
esac


echo "============ RELEVANCE ============"
check "markdown is relevant"      "0" "$(watch_is_relevant a.md; echo $?)"
check ".markdown is relevant"     "0" "$(watch_is_relevant a.markdown; echo $?)"
check "uppercase counts"          "0" "$(watch_is_relevant A.MD; echo $?)"
# A sidecar supplies title and authors, so editing one changes the output while
# the markdown is untouched. v2 watched these and then ignored them in the
# callback, which read to a user as "watch mode doesn't notice my metadata".
check "a .yaml sidecar is relevant"  "0" "$(watch_is_relevant a.yaml; echo $?)"
check "a .yml sidecar is relevant"   "0" "$(watch_is_relevant a.yml; echo $?)"
check "other files are not"          "1" "$(watch_is_relevant notes.txt; echo $?)"
check "a PDF is not"                 "1" "$(watch_is_relevant out.pdf; echo $?)"


echo "============ FINGERPRINT ============"
fixture
F1=$(watch_fingerprint "$BASE/src")
check "irrelevant files are excluded" "" "$(printf '%s\n' "$F1" | grep 'notes.txt')"

# Content changes must show even when the size does not: an edit that swaps one
# character for another is the commonest kind, and a fingerprint that missed it
# would make watch mode look broken in exactly the case it is used for.
sleep 1.1
printf '# Two\n' > "$BASE/src/a.md"
check "an edit changes the fingerprint" "differs" \
      "$([ "$(watch_fingerprint "$BASE/src")" = "$F1" ] && echo same || echo differs)"

fixture
F1=$(watch_fingerprint "$BASE/src")
printf '# New\n' > "$BASE/src/b.md"
check "a new file changes it" "differs" \
      "$([ "$(watch_fingerprint "$BASE/src")" = "$F1" ] && echo same || echo differs)"

rm -f "$BASE/src/b.md"
check "a deletion changes it back" "same" \
      "$([ "$(watch_fingerprint "$BASE/src")" = "$F1" ] && echo same || echo differs)"

fixture
F1=$(watch_fingerprint "$BASE/src")
printf 'ignored\n' > "$BASE/src/other.txt"
check "an irrelevant file does not" "same" \
      "$([ "$(watch_fingerprint "$BASE/src")" = "$F1" ] && echo same || echo differs)"


echo "============ REACTION ============"
fixture
watch_run 1.5 "printf '# Edited\n' > '$BASE/src/a.md'"
check "reacts to an edit" "yes" "$([ "$(hits)" -ge 1 ] && echo yes || echo no)"

fixture
watch_run 1.5 "printf '# Added\n' > '$BASE/src/new.md'"
check "reacts to a new document" "yes" "$([ "$(hits)" -ge 1 ] && echo yes || echo no)"

fixture
watch_run 1.5 "printf 'title: Changed\n' > '$BASE/src/a.yaml'"
check "reacts to a sidecar edit" "yes" "$([ "$(hits)" -ge 1 ] && echo yes || echo no)"

fixture
watch_run 1.5 "printf 'noise\n' > '$BASE/src/scratch.txt'"
check "ignores irrelevant files" "0" "$(hits)"

fixture
watch_run 1.2 "true"
check "quiet directory stays quiet" "0" "$(hits)"


echo "============ CONVERSION FEEDBACK ============"
# Converting writes files, and `pdfulator --watch dir/` writes them into the
# directory being watched. If the baseline is taken before the callback rather
# than after it, everything the conversion produced looks like a fresh change
# on the next poll: one edit converts, the conversion trips the watcher, and
# round it goes.
#
# Measured before the fix: one edit, four conversions. A callback writing a
# watched .yaml sidecar would never have stopped at all.
#
# This is what made the REACTION cases above flaky, and it is why two attempts
# to fix them by adjusting the test's timing both failed -- the fault was in
# watch_dir, not in when the test poked it.
fixture
: > "$BASE/log"
watch_on_change() {
	# A conversion that takes a moment and writes into the watched directory,
	# which is what a real one does.
	sleep 0.4
	printf 'title: generated\n' > "$BASE/src/a.yaml"
	printf 'convert\n' >> "$BASE/log"
}
watch_dir "$BASE/src" >/dev/null 2>&1 &
FB_PID=$!
WATCHERS="$WATCHERS $FB_PID"
sleep 1
printf '# Edited once\n' > "$BASE/src/a.md"
sleep 3
kill "$FB_PID" 2>/dev/null; wait "$FB_PID" 2>/dev/null
pkill -P "$FB_PID" 2>/dev/null
check "one edit converts once" "1" "$(hits)"

echo "============ NON-REPRODUCIBLE OUTPUT ============"
# An engine whose output differs on every run, which is the normal case rather
# than the exception: the vivlio engine stamps /CreationDate and /ModDate into
# every PDF, so converting the same document twice gives two different files.
#
# The feedback loop would otherwise be permanent rather than transient. A
# conversion writes a PDF, the PDF differs from the last one, the difference
# reads as a change, and round it goes forever -- no edit required, and no
# up-to-date check to stop it, since the source really is newer than nothing.
#
# What saves it is that watch_is_relevant excludes .pdf, so PDFs never enter
# the fingerprint at all and a timestamp inside one is invisible. That is a
# property worth pinning rather than assuming: it is the single thing standing
# between "watch mode" and "convert forever", and it would be undone by anyone
# adding .pdf to the relevance list for a plausible-sounding reason.
#
# Harsher than reality on purpose -- the fixture changes the PDF's *size* as
# well as its content, so a fingerprint that noticed either would trip.
for MECH in poll fswatch; do
	PDFULATOR_WATCH=$MECH
	export PDFULATOR_WATCH

	fixture
	: > "$BASE/log"
	watch_on_change() {
		sleep 0.3
		printf '%%PDF-1.4 generated at %s %s\n' "$(date +%s)" "$$" \
			> "$BASE/src/a.pdf"
		printf 'convert\n' >> "$BASE/log"
	}
	watch_dir "$BASE/src" >/dev/null 2>&1 &
	ND_PID=$!
	WATCHERS="$WATCHERS $ND_PID"
	sleep 1
	printf '# Edited once\n' > "$BASE/src/a.md"
	sleep 3
	kill "$ND_PID" 2>/dev/null; wait "$ND_PID" 2>/dev/null
	pkill -P "$ND_PID" 2>/dev/null
	check "$MECH: a timestamped PDF does not re-trigger" "1" "$(hits)"
done
unset PDFULATOR_WATCH

# The sidecar is the case with no such protection, and it is deliberate: .yaml
# is watched, because editing one changes the output while the markdown is
# untouched. So an engine that *wrote* a sidecar on every conversion -- with a
# timestamp, or any changing content -- would loop forever, and nothing here
# would stop it.
#
# No engine does today, and none should: sidecars are input. Recorded as a
# constraint on future engines rather than as a defect, since the alternative
# (dropping .yaml from the fingerprint) breaks the metadata-edit case that the
# RELEVANCE section exists to protect.
check "sidecars are watched, so engines must not write them" "0" \
      "$(watch_is_relevant a.yaml; echo $?)"


echo "============ EVENT WATCHERS ============"
# fswatch and inotifywait, without either being installed.
#
# Neither is present on a stock macOS or in a Docker image, so before this
# section the event branches were never executed anywhere -- not here, not in
# CI -- while being what most developer machines actually select. Both had the
# conversion-feedback loop that d6b0369 fixed for polling, plus an unfiltered
# event stream: watch_is_relevant was consulted only by watch_fingerprint, so
# under fswatch a written .pdf triggered a full re-plan.
#
# The stubs stand in for the real tools at the only interface watch_dir uses:
# a line on stdout per event. That is the whole contract -- watch_dir ignores
# the content of the line and re-plans from the directory -- so a stub exercises
# the branch as faithfully as the tool would, and does it identically on every
# platform. What it cannot test is whether the real tools notice a given
# filesystem change; that is their job and they have their own test suites.
#
# The stubs themselves are installed at the top of this file rather than here:
# see the note there for why they cannot wait until this section.
#

# PDFULATOR_WATCH forces the branch. Without it the stubs would be found by
# watch_mechanism anyway, but only in the preference order -- inotifywait would
# never run on a machine where the fswatch stub exists, which is every machine
# running this file.
for MECH in fswatch inotifywait; do
	PDFULATOR_WATCH=$MECH
	export PDFULATOR_WATCH

	check "$MECH is selected when forced" "$MECH" "$(watch_mechanism)"

	fixture
	watch_run 1.5 "printf '# Edited\n' > '$BASE/src/a.md'"
	check "$MECH reacts to an edit" "yes" "$([ "$(hits)" -ge 1 ] && echo yes || echo no)"

	fixture
	watch_run 1.5 "printf 'title: Changed\n' > '$BASE/src/a.yaml'"
	check "$MECH reacts to a sidecar edit" "yes" \
	      "$([ "$(hits)" -ge 1 ] && echo yes || echo no)"

	# The event branches saw every file in the directory, relevant or not:
	# watch_is_relevant was reached only through watch_fingerprint. A .txt --
	# or an editor's swap file, or a .pdf just written -- meant a full re-plan,
	# and for a container engine a cold container start.
	fixture
	watch_run 1.5 "printf 'noise\n' > '$BASE/src/scratch.txt'"
	check "$MECH ignores irrelevant files" "0" "$(hits)"

	# A PDF specifically, because that is what a conversion writes into the
	# directory it is watching -- the feedback loop's first hop.
	fixture
	watch_run 1.5 "printf '%%PDF-1.4\n' > '$BASE/src/a.pdf'"
	check "$MECH ignores a written PDF" "0" "$(hits)"

	fixture
	watch_run 1.2 "true"
	check "$MECH stays quiet when nothing happens" "0" "$(hits)"

	# The loop this section exists for. The callback writes a *watched* file
	# (a sidecar, as a real conversion may), so the conversion's own output is
	# itself an event. Before the fix this never terminated: each conversion
	# triggered the next.
	#
	# It also pins the subshell trap. The event branches read from a fifo
	# rather than a pipe so the loop body stays in this shell; written as
	# `watcher | while read`, watch_react's baseline would be set in a
	# subshell and lost on every event, and this case would count 2 or more.
	fixture
	: > "$BASE/log"
	watch_on_change() {
		sleep 0.4
		printf 'title: generated\n' > "$BASE/src/a.yaml"
		printf 'convert\n' >> "$BASE/log"
	}
	watch_dir "$BASE/src" >/dev/null 2>&1 &
	FB_PID=$!
	WATCHERS="$WATCHERS $FB_PID"
	sleep 1
	printf '# Edited once\n' > "$BASE/src/a.md"
	sleep 3
	kill "$FB_PID" 2>/dev/null; wait "$FB_PID" 2>/dev/null
	pkill -P "$FB_PID" 2>/dev/null
	check "$MECH converts once per edit" "1" "$(hits)"
done

unset PDFULATOR_WATCH


echo "============ REAL WATCHERS ============"
# The stubs above prove the branch logic. This proves the invocation itself:
# that `fswatch -o <dir>` and `inotifywait -q -m -e ... <dir>` are spelled
# correctly and emit a line per change. A stub cannot show that, since it
# accepts whatever flags it is handed.
#
# Skipped when the tool is absent, which is the normal case on macOS without
# Homebrew and in a Docker image. CI is where these should actually run.
PATH=$(printf '%s' "$PATH" | sed "s|^$STUBS:||")
export PATH

for MECH in fswatch inotifywait; do
	if ! command -v "$MECH" >/dev/null 2>&1; then
		echo "skip  $MECH is not installed here"
		continue
	fi

	PDFULATOR_WATCH=$MECH
	export PDFULATOR_WATCH

	fixture
	watch_run 2 "printf '# Edited\n' > '$BASE/src/a.md'"
	check "real $MECH reacts to an edit" "yes" \
	      "$([ "$(hits)" -ge 1 ] && echo yes || echo no)"

	fixture
	watch_run 2 "printf 'noise\n' > '$BASE/src/scratch.txt'"
	check "real $MECH ignores irrelevant files" "0" "$(hits)"

	unset PDFULATOR_WATCH
done


echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
