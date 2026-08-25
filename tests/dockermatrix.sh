#!/bin/sh
# The vivlio-docker engine's mount construction.
#
# What is under test is the translation from the engine contract to a
# `docker run` command line: which directories get mounted, where they land
# inside the container, and what the three contract arguments become once the
# host's paths are meaningless.
#
# No Docker is required, and that is deliberate rather than a compromise. The
# engine's own logic is entirely in what it *builds*, so a fake docker that
# prints its arguments tests it exactly, and does so on a machine with no
# daemon -- which is most machines, including the one this was written on and
# any CI runner that hasn't paid for a privileged job. Whether the image
# itself converts a document is a different question, answered by building it.
#
# The fake prints one argument per line, so an assertion can look for an exact
# argument rather than a substring: `-v /a/b:/in:ro` must not be satisfied by
# a mount that merely contains that text.
# Both container engines, because the translation is shared (lib/container.sh)
# and a bug in it would otherwise be found in whichever engine happened to be
# tested. Each engine supplies only its name and its built-in theme path, so
# those are what the cases parameterise over.
REPO=$(cd "$(dirname "$0")/.." && pwd)
# Discovered, not listed: every engine declaring needs_docker=yes is tested,
# so adding one cannot quietly skip these cases. The built-in theme path is
# read from the engine's own convert, which is where it is declared -- it is
# not in engine.conf, being an implementation detail of the image rather than
# something a user configures.
ENGINES=$(for _c in "$REPO"/engines/*/engine.conf; do
	[ -f "$_c" ] || continue
	grep -q '^needs_docker=yes' "$_c" || continue
	_id=$(basename -- "$(dirname -- "$_c")")
	_th=$(sed -n 's/^CONTAINER_THEME=//p' "$(dirname -- "$_c")/convert" | head -1)
	[ -n "$_th" ] || _th=/theme
	printf '%s:%s ' "$_id" "$_th"
done)

BASE=$(printf '%s' "${TMPDIR:-/tmp}" | sed 's|/*$||')/pdfulator-dockermatrix.$$
FAIL=0
trap 'rm -rf "$BASE"' EXIT INT TERM

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

fixture() {
	rm -rf "$BASE"
	mkdir -p "$BASE/bin" "$BASE/src" "$BASE/out" "$BASE/dist/theme" \
	         "$BASE/my themes/plain"
	printf '# One\n' > "$BASE/src/a.md"
	printf 'body{}\n' > "$BASE/dist/theme/style.css"
	printf 'body{}\n' > "$BASE/my themes/plain/style.css"

	cat > "$BASE/bin/docker" <<'FAKE'
#!/bin/sh
for _a in "$@"; do printf '%s\n' "$_a"; done
FAKE
	chmod +x "$BASE/bin/docker"

	PDFULATOR_DOCKER="$BASE/bin/docker"
	PDFULATOR_DIR="$BASE/dist"
	export PDFULATOR_DOCKER PDFULATOR_DIR
	unset PDFULATOR_VERBOSE PDFULATOR_DEBUG PDFULATOR_IMAGE 2>/dev/null || true
}

# Run the engine and keep what the fake docker was handed.
run() {  # run <in> <out> <theme>
	( cd "$BASE" && "$ENGINE_DIR/convert" "$1" "$2" "$3" 2>"$BASE/err" )
}

# Is this exact argument present?
#
# `-e --` is not decoration: the arguments being looked for are docker flags,
# so most of them start with a dash, and grep reads a leading-dash pattern
# given positionally as its own option -- "grep: unrecognized option --rm".
# The assertion then fails while the engine is perfectly correct, which is the
# worst kind of test.
has() {  # has <output> <argument>
	printf '%s\n' "$1" | grep -qxF -e "$2" && echo yes || echo no
}

# The last three arguments are the contract, in order.
contract() {  # contract <output>
	printf '%s\n' "$1" | tail -3 | tr '\n' ' ' | sed 's/ $//'
}


for _spec in $ENGINES; do
	ENGINE=${_spec%%:*}
	BUILTIN=${_spec#*:}
	ENGINE_DIR=$REPO/engines/$ENGINE
	IMAGE=$(sed -n 's/^[[:space:]]*image[[:space:]]*=[[:space:]]*//p' \
	        "$ENGINE_DIR/engine.conf" | head -1)

	echo
	echo "################ $ENGINE ################"

	echo "============ CONTRACT ============"
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	# The three contract arguments are rewritten to container paths, in order, and
	# nothing else follows them -- an engine that appended its own flag after the
	# theme would break every image's argument parsing.
	check "contract args are container paths" "/in/a.md /out/a.pdf /theme" \
	      "$(contract "$OUT")"
	check "the image is named" "yes" "$(has "$OUT" "$IMAGE")"
	check "the run is disposable" "yes" "$(has "$OUT" "--rm")"
	# --init, so that ^C reaches the browser rather than leaving a zombie Chromium
	# holding the container open.
	check "an init process is used" "yes" "$(has "$OUT" "--init")"


	echo "============ INPUT ============"
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	# The document's *directory*, not the document: relative image references
	# resolve against the document, and a single-file bind mount pins an inode
	# that an editor's write-and-rename replaces.
	check "the input directory is mounted read-only" "yes" \
	      "$(has "$OUT" "$BASE/src:/in:ro")"
	check "the input file is not mounted" "no" \
	      "$(has "$OUT" "$BASE/src/a.md:/in:ro")"

	fixture
	OUT=$(printf '# Hi\n' | ( cd "$BASE" && "$ENGINE_DIR/convert" - - "" 2>/dev/null ))
	check "stdin needs no input mount" "no" "$(has "$OUT" "$BASE/src:/in:ro")"
	# Without -i the container's stdin is closed and the engine reads an empty
	# document, which fails as "empty input on stdin" rather than as a plumbing
	# mistake -- so this flag is the difference between working and a confusing
	# error.
	check "stdin keeps the container's stdin open" "yes" "$(has "$OUT" "-i")"
	check "stdin stays stdin in the container" "- - $BUILTIN" "$(contract "$OUT")"

	fixture
	run "$BASE/src/nope.md" "$BASE/out/a.pdf" "$BASE/dist/theme" >/dev/null 2>&1
	check "a missing input fails before docker runs" "1" "$?"


	echo "============ OUTPUT ============"
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	check "the output directory is mounted writable" "yes" \
	      "$(has "$OUT" "$BASE/out:/out")"
	check "the output directory is not read-only" "no" \
	      "$(has "$OUT" "$BASE/out:/out:ro")"

	# docker creates a missing mount source itself, as root, which is a surprising
	# thing for a conversion to leave behind. The engine creates it first, as the
	# user.
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/fresh/a.pdf" "$BASE/dist/theme")
	check "a missing output directory is created" "yes" \
	      "$([ -d "$BASE/out/fresh" ] && echo yes || echo no)"
	check "and mounted" "yes" "$(has "$OUT" "$BASE/out/fresh:/out")"

	fixture
	OUT=$(run "$BASE/src/a.md" - "$BASE/dist/theme")
	check "stdout needs no output mount" "no" "$(has "$OUT" "$BASE/out:/out")"

	# `pdfulator dir/` writes each PDF beside its source, so this is the common
	# case rather than an edge one: one host directory, two container paths. Both
	# mounts must be present -- a container given only the read-only /in has
	# nowhere to put the PDF.
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/src/a.pdf" "$BASE/dist/theme")
	check "same dir in and out: read-only in" "yes" \
	      "$(has "$OUT" "$BASE/src:/in:ro")"
	check "same dir in and out: writable out" "yes" \
	      "$(has "$OUT" "$BASE/src:/out")"
	check "and the contract names both" "/in/a.md /out/a.pdf /theme" \
	      "$(contract "$OUT")"


	echo "============ THEME ============"
	# Every theme given is mounted, including one that happens to live inside
	# the install directory.
	#
	# There used to be a special case here: a theme equal to $PDFULATOR_DIR/theme
	# was *not* mounted, since the image already carried an identical copy. That
	# stopped being true when the wrapper began staging themes -- what arrives
	# now is a directory built per engine under $PDFULATOR_HOME/cache, holding
	# the concatenated CSS, the fetched fonts and the generated configuration.
	# Skipping the mount would hand the container the theme baked in at build
	# time and silently ignore the user's, which is a wrong PDF rather than an
	# error. The image's own copy is only the fallback when no theme is given.
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	check "a theme inside the install dir is still mounted" "yes" \
	      "$(has "$OUT" "$BASE/dist/theme:/theme:ro")"
	check "and becomes /theme" "/theme" \
	      "$(printf '%s\n' "$OUT" | tail -1)"

	# No theme at all: nothing to mount, so the image's own copy is used.
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "")
	check "no theme falls back to the image's copy" "$BUILTIN" \
	      "$(printf '%s\n' "$OUT" | tail -1)"
	check "and mounts nothing at /theme" "no" \
	      "$(has "$OUT" ":/theme:ro")"

	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/my themes/plain")
	check "a user theme is mounted read-only" "yes" \
	      "$(has "$OUT" "$BASE/my themes/plain:/theme:ro")"
	check "a user theme becomes /theme" "/theme" \
	      "$(printf '%s\n' "$OUT" | tail -1)"

	# A theme path containing a space is one argument, not two. It arrives here
	# already resolved by the wrapper, so this is about not breaking it: a mount
	# built by string concatenation and then word-split would send docker "-v",
	# "/base/my", "themes/plain:/theme:ro" and fail with a message naming a path
	# the user never typed.
	check "a space in the theme path survives" "1" \
	      "$(printf '%s\n' "$OUT" | grep -c "^$BASE/my themes/plain:/theme:ro$")"


	echo "============ OWNERSHIP ============"
	# On Linux the image's own user writes the PDF, and its uid is not the
	# caller's, so the file lands unwritable by the person who asked for it.
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	if [ "$(id -u)" = 0 ]; then
		check "root is left alone" "no" "$(has "$OUT" "--user")"
	else
		check "the caller's uid is passed" "yes" "$(has "$OUT" "--user")"
		check "as uid:gid" "yes" "$(has "$OUT" "$(id -u):$(id -g)")"

		# A uid passed with --user exists in no /etc/passwd inside the image and
		# so has no home directory. Chromium's crash reporter needs one, and says
		# so in a way that names neither Chromium nor HOME:
		#   chrome_crashpad_handler: --database is required
		# This was found by running the image, not by reading it: bare stdin mode
		# passes no --user and never meets it.
		check "a writable HOME goes with the uid" "yes" \
		      "$(has "$OUT" "HOME=/tmp")"
	fi


	echo "============ ENVIRONMENT ============"
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	check "quiet by default" "no" "$(has "$OUT" "PDFULATOR_VERBOSE=1")"

	fixture
	PDFULATOR_VERBOSE=1 && export PDFULATOR_VERBOSE
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	check "verbosity travels into the container" "yes" \
	      "$(has "$OUT" "-e")"
	check "as PDFULATOR_VERBOSE" "yes" "$(has "$OUT" "PDFULATOR_VERBOSE=1")"
	unset PDFULATOR_VERBOSE


	echo "============ IMAGE ============"
	# Read from engine.conf rather than hardcoded, so the tag the engine declares
	# and the tag it runs cannot disagree.
	fixture
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	check "the configured image is used" "yes" \
	      "$(has "$OUT" "$IMAGE")"

	fixture
	PDFULATOR_IMAGE=example/local:test && export PDFULATOR_IMAGE
	OUT=$(run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme")
	check "an override is honoured" "yes" "$(has "$OUT" "example/local:test")"
	check "and replaces the default" "no" "$(has "$OUT" "$IMAGE")"
	unset PDFULATOR_IMAGE


	echo "============ MISSING DOCKER ============"
	# The engine is reached with docker absent when someone runs it directly; the
	# wrapper checks first, but the engine must not simply report "not found" from
	# a shell.
	fixture
	PDFULATOR_DOCKER="$BASE/bin/nosuchdocker" && export PDFULATOR_DOCKER
	run "$BASE/src/a.md" "$BASE/out/a.pdf" "$BASE/dist/theme" >/dev/null 2>&1
	check "absent docker is an error" "1" "$?"
	check "and says which engine to use instead" "yes" \
	      "$(grep -q 'engine vivlio' "$BASE/err" && echo yes || echo no)"


	echo "============ PULL ============"
	# Fetching the image before the first conversion rather than during it.
	#
	# `docker run` would pull on its own, which is the problem being solved:
	# the download then happens mid-job, so several hundred megabytes of
	# progress arrive on stderr interleaved with the engine's own output, and
	# an unreachable registry produces a docker error about a manifest instead
	# of a pdfulator one about an engine.
	#
	# A second fake, because these cases need docker to *answer* rather than
	# just record: whether the image is present is the whole question.
	pullfix() {  # pullfix — a docker that reports the image present or not
		fixture
		cat > "$BASE/bin/docker" <<FAKE
#!/bin/sh
printf '%s\n' "\$1" >> "$BASE/calls"
case \$1 in
	image) [ -f "$BASE/present" ] && exit 0 || exit 1 ;;
	pull)  exit \${FAKE_PULL_RC:-0} ;;
esac
exit 0
FAKE
		chmod +x "$BASE/bin/docker"
		: > "$BASE/calls"
		rm -f "$BASE/present"
		# The engine's convert execs docker directly; container_pull is what is
		# under test, so it is called on its own.
		. "$REPO/lib/container.sh"
	}

	pullfix
	container_pull "$ENGINE_DIR" "$ENGINE" >/dev/null 2>&1
	check "an absent image is pulled" "yes" \
	      "$(grep -qx pull "$BASE/calls" && echo yes || echo no)"

	# `image inspect` rather than `images -q`: the latter matches on the
	# repository, so a differently *tagged* build of the same repository
	# reports present and the run pulls mid-conversion after all.
	pullfix
	touch "$BASE/present"
	container_pull "$ENGINE_DIR" "$ENGINE" >/dev/null 2>&1
	check "a present image is not pulled" "no" \
	      "$(grep -qx pull "$BASE/calls" && echo yes || echo no)"

	# Announced, not asked about: this runs in CI and in scripts, where a
	# prompt is a hang. The message has to name the image, since "fetching an
	# image" during an unrelated command is otherwise unexplained.
	pullfix
	ERR=$(container_pull "$ENGINE_DIR" "$ENGINE" 2>&1 >/dev/null)
	check "the fetch is announced" "yes" \
	      "$(printf '%s' "$ERR" | grep -qF "$IMAGE" && echo yes || echo no)"

	# A failed pull stops the run. Conversion would otherwise proceed to a
	# `docker run` that pulls again and fails less clearly.
	pullfix
	FAKE_PULL_RC=1 container_pull "$ENGINE_DIR" "$ENGINE" >/dev/null 2>&1
	check "a failed pull fails" "1" "$?"
	pullfix
	ERR=$(FAKE_PULL_RC=1 container_pull "$ENGINE_DIR" "$ENGINE" 2>&1 >/dev/null)
	check "and names the bundled alternative" "yes" \
	      "$(printf '%s' "$ERR" | grep -q 'engine vivlio' && echo yes || echo no)"

	# $PDFULATOR_IMAGE points at a local build, and must be what gets checked
	# for and fetched -- not the tag in engine.conf.
	pullfix
	PDFULATOR_IMAGE=my/own:build
	export PDFULATOR_IMAGE
	ERR=$(container_pull "$ENGINE_DIR" "$ENGINE" 2>&1 >/dev/null)
	check "an image override is honoured" "yes" \
	      "$(printf '%s' "$ERR" | grep -qF 'my/own:build' && echo yes || echo no)"
	unset PDFULATOR_IMAGE


	echo "============ SET -E ============"
	# The library does not set -e; the wrapper does, and the engine sets it itself.
	# Three bugs in lib/browser.sh were invisible until the tests ran under it.
	fixture
	sh -c "set -e; PDFULATOR_DOCKER='$BASE/bin/docker' PDFULATOR_DIR='$BASE/dist' \
	       '$ENGINE_DIR/convert' '$BASE/src/a.md' '$BASE/out/a.pdf' '$BASE/dist/theme'" \
		>/dev/null 2>&1
	check "convert survives set -e" "0" "$?"
done

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
