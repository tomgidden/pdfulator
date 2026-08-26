#!/bin/sh
# PDFULATOR_SOURCE matrix. Installing from a checkout rather than a tarball.
#
# The property worth protecting is equivalence: an install from source must
# produce the same tree as an install from the tarball built out of that same
# source. If the two drift, then --uninstall, --update and the manifest all
# start behaving differently depending on how the user happened to install,
# which is exactly the class of bug nobody reports because it only bites later.
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${TMPDIR:-/tmp}/pdfulator-sourcematrix
FAIL=0

ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=1; }
is()   { # is <label> <got> <want>
	if [ "$2" = "$3" ]; then ok "$1"; else
		bad "$1"; printf '        got:  %s\n        want: %s\n' "$2" "$3"; fi
}

rm -rf "$S"; mkdir -p "$S"

echo "============ INSTALLING FROM A CHECKOUT ============"

PDFULATOR_HOME=$S/src PDFULATOR_BIN=$S/srcbin PDFULATOR_SOURCE=$REPO \
	sh "$REPO/install.sh" >"$S/src.log" 2>&1
is "the install succeeds" "$?" "0"

[ -d "$S/src/lib" ]     && ok "lib/ arrives"      || bad "lib/ arrives"
[ -d "$S/src/engines" ] && ok "engines/ arrives"  || bad "engines/ arrives"
[ -d "$S/src/themes" ]  && ok "themes/ arrives"   || bad "themes/ arrives"
# templates/ is a shipped top-level directory too: without it every engine
# silently falls back to whatever built-in template it carries.
[ -d "$S/src/templates" ] && ok "templates/ arrives" || bad "templates/ arrives"

# The wrapper is pdfulator.sh in a checkout and pdfulator once installed.
# Everything downstream -- the manifest, the PATH copy, --uninstall -- expects
# the installed name, so the rename is not cosmetic.
[ -f "$S/src/pdfulator" ]    && ok "the wrapper is renamed" || bad "the wrapper is renamed"
[ -x "$S/src/pdfulator" ]    && ok "and executable"         || bad "and executable"
[ -f "$S/src/pdfulator.sh" ] && bad "the checkout name is not kept" \
                             || ok "the checkout name is not kept"

# install.sh ships inside the installation as well as beside it: --update
# re-runs it rather than reimplementing download, verify, stage and swap.
[ -f "$S/src/install.sh" ] && ok "install.sh rides along" || bad "install.sh rides along"

# node_modules is as platform-specific as it is in a release. Copying the
# developer's tree would hand the installation their architecture.
found=$(find "$S/src" -name node_modules -type d 2>/dev/null | wc -l | tr -d ' ')
is "no node_modules is copied" "$found" "0"

echo
echo "============ THE VERSION ============"

# A checkout has no release tag of its own, so it asks git the same question
# the GNUmakefile does. The -dirty suffix matters: it is what stops --update
# from offering to replace a work in progress with a release.
ver=$(cat "$S/src/VERSION" 2>/dev/null)
[ -n "$ver" ] && ok "a version is recorded" || bad "a version is recorded"
expect=$(cd "$REPO" && git describe --tags --always --dirty 2>/dev/null)
if [ -n "$expect" ]; then
	is "it is what git describe says" "$ver" "$expect"
fi

# Outside a git repository there is no describe to ask, and an empty VERSION
# would leave --version printing nothing at all.
mkdir -p "$S/nogit"
cp -R "$REPO/lib" "$REPO/engines" "$REPO/themes" "$REPO/templates" \
	"$S/nogit/" 2>/dev/null
cp "$REPO/pdfulator.sh" "$REPO/install.sh" "$S/nogit/"
PDFULATOR_HOME=$S/ng PDFULATOR_BIN=$S/ngbin PDFULATOR_SOURCE=$S/nogit \
	sh "$REPO/install.sh" >/dev/null 2>&1
ngver=$(cat "$S/ng/VERSION" 2>/dev/null)
[ -n "$ngver" ] && ok "a non-git source still gets one" \
               || bad "a non-git source still gets one"

echo
echo "============ REFUSALS ============"

# A wrong PDFULATOR_SOURCE is the likely user error, and it must be caught
# before anything is written -- a half-installed tree that looks complete is
# worse than a clear refusal.
PDFULATOR_HOME=$S/bad1 PDFULATOR_BIN=$S/bad1bin PDFULATOR_SOURCE=/no/such/dir \
	sh "$REPO/install.sh" >/dev/null 2>&1
is "a missing directory fails" "$?" "1"
[ -d "$S/bad1" ] && bad "and installs nothing" || ok "and installs nothing"

mkdir -p "$S/empty"
PDFULATOR_HOME=$S/bad2 PDFULATOR_BIN=$S/bad2bin PDFULATOR_SOURCE=$S/empty \
	sh "$REPO/install.sh" >/dev/null 2>&1
is "a directory that isn't a checkout fails" "$?" "1"
[ -d "$S/bad2" ] && bad "and installs nothing" || ok "and installs nothing"

echo
echo "============ SAME AS A TARBALL INSTALL ============"

# A tarball older than the sources it was built from would fail this
# comparison for a reason that is not a defect -- test-lib is the suite you
# run while working, and it does not build one. Stale is skipped, not failed.
stale=""
if [ -f "$REPO/pdfulator.tar.gz" ]; then
	for f in "$REPO/install.sh" "$REPO/pdfulator.sh"; do
		[ "$f" -nt "$REPO/pdfulator.tar.gz" ] && stale=$f
	done
	[ -n "$(find "$REPO/lib" "$REPO/engines" "$REPO/themes" "$REPO/templates" -type f \
	          -newer "$REPO/pdfulator.tar.gz" 2>/dev/null | head -1)" ] &&
		stale=${stale:-sources}
fi

if [ ! -f "$REPO/pdfulator.tar.gz" ]; then
	echo "SKIP  no tarball built; run \`make dist\` for the equivalence check"
elif [ -n "$stale" ]; then
	echo "SKIP  ./pdfulator.tar.gz is older than the sources; run \`make dist\`"
else
	PDFULATOR_HOME=$S/tar PDFULATOR_BIN=$S/tarbin \
		PDFULATOR_TARBALL="$REPO/pdfulator.tar.gz" \
		sh "$REPO/install.sh" >/dev/null 2>&1

	# .installed is a timestamp, so it differs by construction.
	a=$(cd "$S/src" && find . -type f ! -name .installed | sort)
	b=$(cd "$S/tar" && find . -type f ! -name .installed | sort)
	is "the same files are installed" "$a" "$b"

	# Content too, not just names -- including the manifest, which is what
	# --uninstall walks. A manifest that disagreed would strand files.
	if diff -r -q "$S/src" "$S/tar" 2>/dev/null | grep -qv '\.installed'; then
		bad "with the same content"
		diff -r -q "$S/src" "$S/tar" 2>/dev/null | grep -v '\.installed' | sed 's/^/        /'
	else
		ok "with the same content"
	fi
fi

echo
echo "============ AND UNINSTALLS CLEANLY ============"

# The point of the equivalence above: a source install is a real installation,
# so the manifest describes it accurately and removal takes everything.
out=$(PDFULATOR_HOME=$S/src PDFULATOR_BIN=$S/srcbin "$S/srcbin/pdfulator" --uninstall 2>&1)
[ -d "$S/src" ] && bad "the application directory goes" \
               || ok "the application directory goes"
[ -e "$S/srcbin/pdfulator" ] && bad "the command goes" || ok "the command goes"
printf '%s' "$out" | grep -q 'Removed' && ok "and says so" || bad "and says so"

rm -rf "$S"
echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
