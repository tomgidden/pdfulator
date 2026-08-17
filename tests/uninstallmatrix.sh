#!/bin/bash
# Uninstall matrix. What --uninstall removes, what it must keep, and what it
# says about the difference.
#
# The rule: anything we shipped and the user hasn't touched goes; anything they
# added or edited stays, and then so does the directory holding it. If nothing
# is left, the directory goes too -- "kept ... (0 files remain)" is a bug, not
# a state.
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${TMPDIR:-/tmp}/pdfulator-uninstallmatrix
FAIL=0

export PDFULATOR_HOME=$S/home
export PDFULATOR_BIN=$S/bin

fresh() {
	rm -rf "$S"; mkdir -p "$S"
	PDFULATOR_TARBALL=$REPO/pdfulator.tar.gz sh "$REPO/install.sh" >/dev/null 2>&1
}

# want <label> <exists|gone> <path>
want() {
	local label=$1 expect=$2 path=$3 got
	if [ -e "$path" ]; then got=exists; else got=gone; fi
	if [ "$got" = "$expect" ]; then
		printf '  %-42s %s\n' "$label" "$got"
	else
		printf '  %-42s %s  EXPECTED %s\n' "$label" "$got" "$expect"
		FAIL=1
	fi
}

# The output must not claim files remain when none do, nor vice versa.
check_message() {
	local out=$1
	if [ -d "$PDFULATOR_HOME" ]; then
		printf '%s' "$out" | grep -q 'Kept' || {
			printf '  %-42s %s\n' "message" "SAID REMOVED BUT DIRECTORY REMAINS"; FAIL=1; }
		printf '%s' "$out" | grep -q '(0 file(s) remain)' && {
			printf '  %-42s %s\n' "message" "CLAIMED 0 FILES BUT KEPT DIRECTORY"; FAIL=1; }
	else
		printf '%s' "$out" | grep -q 'Removed' || {
			printf '  %-42s %s\n' "message" "DIRECTORY GONE BUT DIDN'T SAY SO"; FAIL=1; }
	fi
	return 0
}

echo "===== a clean install leaves nothing behind ====="
fresh
out=$("$PDFULATOR_BIN/pdfulator" --uninstall 2>&1)
want "application directory" gone   "$PDFULATOR_HOME"
want "installed command"     gone   "$PDFULATOR_BIN/pdfulator"
check_message "$out"

echo
echo "===== a stale pin is not user content ====="
# Regression: a leftover .runtime kept the directory alive while the count of
# modified files was 0, so it reported "Kept ... (0 file(s) remain)".
fresh
echo /some/old/bun > "$PDFULATOR_HOME/.runtime"
out=$("$PDFULATOR_BIN/pdfulator" --uninstall 2>&1)
want "application directory" gone   "$PDFULATOR_HOME"
check_message "$out"

echo
echo "===== an edited file is kept, and keeps its directory ====="
fresh
echo '/* mine */' >> "$PDFULATOR_HOME/theme/print.css"
out=$("$PDFULATOR_BIN/pdfulator" --uninstall 2>&1)
want "edited file"           exists "$PDFULATOR_HOME/theme/print.css"
want "untouched shipped file" gone  "$PDFULATOR_HOME/lib/jobs.sh"
check_message "$out"

echo
echo "===== an added theme is kept ====="
fresh
mkdir -p "$PDFULATOR_HOME/themes/mine"
echo 'body{}' > "$PDFULATOR_HOME/themes/mine/print.css"
out=$("$PDFULATOR_BIN/pdfulator" --uninstall 2>&1)
want "added theme"           exists "$PDFULATOR_HOME/themes/mine/print.css"
check_message "$out"

echo
echo "===== a checkout is never mistaken for an installation ====="
# Running the repo's own script must remove the *installed* copy and leave the
# working tree alone.
fresh
out=$(cd "$REPO" && ./pdfulator.sh --uninstall 2>&1)
want "checkout script"       exists "$REPO/pdfulator.sh"
want "installed command"     gone   "$PDFULATOR_BIN/pdfulator"
want "application directory" gone   "$PDFULATOR_HOME"

echo
echo "===== uninstalling twice is not an error message about nothing ====="
fresh
"$PDFULATOR_BIN/pdfulator" --uninstall >/dev/null 2>&1
# The command is gone, so use the checkout's copy against the empty home.
(cd "$REPO" && ./pdfulator.sh --uninstall >/dev/null 2>&1)
if [ $? -eq 1 ]; then
	printf '  %-42s %s\n' "second uninstall" "refused (exit 1)"
else
	printf '  %-42s %s\n' "second uninstall" "EXPECTED exit 1"; FAIL=1
fi

rm -rf "$S"
echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
