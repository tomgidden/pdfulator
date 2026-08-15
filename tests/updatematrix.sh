#!/bin/bash
# Update matrix. Exercises `pdfulator --update` against a local release server,
# so nothing here touches the network or needs a real release to exist.
#
# Two versions are built from the current tree (v2.0.0 and v2.1.0) and served
# from a directory laid out like GitHub's release assets. install.sh and the
# wrapper are pointed at it with PDFULATOR_RELEASE_BASE and
# PDFULATOR_MANIFEST_URL.
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${TMPDIR:-/tmp}/pdfulator-updatematrix
SERVE=$S/serve
H=$S/home
B=$S/bin
PORT=${PDFULATOR_TEST_PORT:-8899}
FAIL=0

OLD=v2.0.0
NEW=v2.1.0

cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

# --- build two releases -------------------------------------------------

rm -rf "$S"; mkdir -p "$SERVE" "$H" "$B"

for v in $OLD $NEW; do
	( cd "$REPO" && make -s dist VERSION=$v >/dev/null ) || exit 1
	d=$SERVE/releases/download/$v
	mkdir -p "$d"
	cp "$REPO/pdfulator.tar.gz" "$d/pdfulator.tar.gz"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$d/pdfulator.tar.gz"
	else
		shasum -a 256 "$d/pdfulator.tar.gz"
	fi | sed 's|  .*|  pdfulator.tar.gz|' > "$d/pdfulator.tar.gz.sha256"
done
mkdir -p "$SERVE/releases/latest/download"
cp "$SERVE/releases/download/$NEW"/* "$SERVE/releases/latest/download/"

base=http://127.0.0.1:$PORT
{
	printf '# pdfulator releases -- version\ttarball\tsha256\n'
	for v in $NEW $OLD; do
		printf '%s\t%s/releases/download/%s/pdfulator.tar.gz\t%s/releases/download/%s/pdfulator.tar.gz.sha256\n' \
			"$v" "$base" "$v" "$base" "$v"
	done
} > "$SERVE/manifest"

( cd "$SERVE" && python3 -m http.server "$PORT" >/dev/null 2>&1 & echo $! > "$S/pid" )
SERVER_PID=$(cat "$S/pid")
sleep 1
curl -fsS "$base/manifest" >/dev/null || { echo "test server didn't start"; exit 1; }

export PDFULATOR_HOME=$H PDFULATOR_BIN=$B
export PDFULATOR_RELEASE_BASE=$base/releases
export PDFULATOR_MANIFEST_URL=$base/manifest

P=$B/pdfulator

# --- helpers ------------------------------------------------------------

install_old() {
	rm -rf "$H" "$B"
	PDFULATOR_VERSION=$OLD sh "$REPO/install.sh" >/dev/null 2>&1
}

# check <label> <want-exit> <command...>
check() {
	local label=$1 want=$2; shift 2
	"$@" >/dev/null 2>&1
	local got=$?
	if [ "$got" = "$want" ]; then
		printf '%-46s exit=%s\n' "$label" "$got"
	else
		printf '%-46s exit=%s  EXPECTED %s\n' "$label" "$got" "$want"
		FAIL=1
	fi
}

# expect_version <label> <want>
expect_version() {
	local got; got=$(cat "$H/VERSION" 2>/dev/null)
	if [ "$got" = "$2" ]; then
		printf '%-46s %s\n' "$1" "$got"
	else
		printf '%-46s %s  EXPECTED %s\n' "$1" "$got" "$2"
		FAIL=1
	fi
}

echo "===== a fresh install carries a version ====="
install_old
expect_version "installed version" "$OLD"
check "--version" 0 "$P" --version

echo
echo "===== --check reports without changing anything ====="
# 0 means "an update is available" so it can drive a shell conditional.
check "--update --check (behind)" 0 "$P" --update --check
expect_version "still" "$OLD"

echo
echo "===== nothing happens without consent ====="
check "--update, no tty, no --yes" 1 sh -c "$P --update </dev/null"
expect_version "still" "$OLD"

echo
echo "===== the user's choices survive an update ====="
echo /usr/bin/fake-chrome > "$H/.browser"
echo /usr/bin/fake-bun    > "$H/.runtime"
mkdir -p "$H/themes/mine" && echo 'body{}' > "$H/themes/mine/print.css"

check "--update --yes" 0 "$P" --update --yes
expect_version "updated to" "$NEW"
for f in .browser .runtime themes/mine/print.css; do
	if [ -e "$H/$f" ]; then
		printf '%-46s kept\n' "  $f"
	else
		printf '%-46s LOST\n' "  $f"; FAIL=1
	fi
done

echo
echo "===== up to date is not an update ====="
# Non-zero here is the point: `--check && --update` must not loop forever.
check "--update --check (current)" 1 "$P" --update --check
check "--update --yes (current)" 0 "$P" --update --yes
expect_version "still" "$NEW"

echo
echo "===== a local build is not overwritten by accident ====="
echo "v2.0.0-3-gabc1234-dirty" > "$H/VERSION"
check "--update --yes (dev build)" 1 "$P" --update --yes
expect_version "still" "v2.0.0-3-gabc1234-dirty"
check "--update --yes --force" 0 "$P" --update --yes --force
expect_version "forced to" "$NEW"

echo
echo "===== PDFULATOR_VERSION pins, including downgrade ====="
check "--update --yes (to $OLD)" 0 env PDFULATOR_VERSION=$OLD "$P" --update --yes
expect_version "downgraded to" "$OLD"

echo
echo "===== modifiers are rejected outside --update ====="
check "--yes without --update" 1 "$P" --yes foo.md
check "--check without --update" 1 "$P" --check
check "--update --uninstall" 1 "$P" --update --uninstall

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
