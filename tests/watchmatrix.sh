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

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-watchmatrix
FAIL=0

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
# The sleep before the action is what makes this deterministic: a change made
# before the watcher has taken its first fingerprint is not a change it can
# see, and the test would fail for a reason that has nothing to do with the
# code under test.
watch_run() {  # watch_run <timeout> <action>
	: > "$BASE/log"
	watch_on_change() { printf 'convert %s\n' "$1" >> "$BASE/log"; }

	watch_dir "$BASE/src" >/dev/null 2>&1 &
	_wr_pid=$!

	sleep 0.5
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

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
