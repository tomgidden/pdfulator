#!/bin/sh
# The CI workflows, as static properties.
#
# CI is the one part of this repository that cannot be run locally: a mistake
# here is found by pushing, waiting for a runner, and reading a log. That makes
# the cheap checks worth having -- the failures below are all things that would
# otherwise cost a full round trip through GitHub.
#
# Written after item 6 of the roadmap turned one image into three. Two of these
# are regressions the generalisation itself introduced or exposed:
#
#   1. `bun install --frozen-lockfile` still ran at the repository root, where
#      v3 has no package.json at all -- the lockfile moved into the engine that
#      owns it. Every tagged release would have failed at the `dist` job.
#   2. Engines were discovered in three places by the same rule (GNUmakefile,
#      tests/dockermatrix.sh, and now ci.yaml). A fourth engine added to two of
#      them builds an image nothing pulls, or pulls one nothing built.
#
# What this does NOT check is that the workflows run: only that they say what
# they must. Anything needing a runner belongs in the run itself.
REPO=$(cd "$(dirname "$0")/.." && pwd)
CI=$REPO/.github/workflows/ci.yaml
BAKE=$REPO/.github/workflows/docker-bake.hcl
FAIL=0

check() {  # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		FAIL=1
	fi
}

# The same discovery rule the GNUmakefile and dockermatrix use. Restated rather
# than shared because that is the property under test: if this drifts from
# engine.conf, so has CI.
ENGINES=$(for _c in "$REPO"/engines/*/engine.conf; do
	[ -f "$_c" ] || continue
	grep -q '^needs_docker=yes' "$_c" || continue
	_d=${_c%/engine.conf}
	basename "$_d"
done)


echo "============ THE WORKFLOWS PARSE ============"
# A workflow with a YAML error does not fail loudly -- GitHub declines to run
# it, and the push looks like it simply triggered nothing.
if command -v python3 >/dev/null 2>&1 &&
   python3 -c 'import yaml' >/dev/null 2>&1; then
	for f in ci.yaml pages.yaml; do
		check "$f is valid YAML" "0" \
		      "$(python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' \
		         "$REPO/.github/workflows/$f" >/dev/null 2>&1; echo $?)"
	done
else
	echo "SKIP: no python3 with PyYAML; cannot parse-check the workflows."
fi


echo "============ ENGINES ARE DISCOVERED, NOT LISTED ============"
# The point of the matrix: adding engines/<id>/ is the whole of adding it to
# CI. A hardcoded engine id in ci.yaml is the failure this guards.
check "at least one container engine exists" "yes" \
      "$([ -n "$ENGINES" ] && echo yes || echo no)"

check "ci.yaml discovers engines from engine.conf" "yes" \
      "$(grep -q 'needs_docker=yes' "$CI" && echo yes || echo no)"

# Every container engine must reach the build. Discovery means no engine is
# named in ci.yaml, so the check is the inverse: none of them may be.
for e in $ENGINES; do
	check "$e is not hardcoded in ci.yaml" "0" \
	      "$(grep -c "matrix.engine.*$e\|engine: .*$e" "$CI")"
done


echo "============ IMAGE TAGS MATCH engine.conf ============"
# engine.conf's `image=` is what an installed pdfulator pulls at run time.
# Building under any other name produces images nobody ever fetches -- and the
# failure appears at a user's first run, not in CI.
for e in $ENGINES; do
	conf=$REPO/engines/$e/engine.conf
	image=$(sed -n 's/^image=//p' "$conf" | head -1)

	check "$e declares an image" "yes" \
	      "$([ -n "$image" ] && echo yes || echo no)"
	check "$e's image has a tag" "yes" \
	      "$(echo "$image" | grep -q ':' && echo yes || echo no)"

	# Docker Hub for now, deliberately, though ghcr is where this is headed
	# -- same ecosystem as the source and the releases, and no v1/v2 legacy.
	# The blocker is that a GHCR package is PRIVATE on first publish, unlike
	# Docker Hub, so an anonymous `docker pull` gets 401/403 and every user
	# without a GHCR login breaks. Switching needs the package made public
	# first; planned for the move to the pdfulator org, where visibility gets
	# set fresh anyway. CI already pushes to both, so the switch is this key.
	check "$e pulls from a public registry" "yes" \
	      "$(echo "$image" | grep -q '^ghcr\.io/' && echo no || echo yes)"

	# CI derives the tag by stripping everything up to the colon, so a tag
	# containing one would silently truncate.
	tag=${image##*:}
	check "$e's tag is not empty" "yes" \
	      "$([ -n "$tag" ] && echo yes || echo no)"
done

# Tags must be unique, or two engines overwrite each other in the registry and
# the last one built wins.
check "every engine's tag is distinct" "yes" \
      "$(n=0; u=0
         for e in $ENGINES; do
           n=$((n+1))
         done
         u=$(for e in $ENGINES; do
               sed -n 's/^image=//p' "$REPO/engines/$e/engine.conf" |
               head -1 | sed 's/.*://'
             done | sort -u | wc -l | tr -d ' ')
         [ "$n" = "$u" ] && echo yes || echo no)"


# Publishing is deliberately wider than pulling: both registries get every
# image, so switching engine.conf back to Docker Hub needs no CI change.
check "CI still publishes to Docker Hub" "yes" \
      "$(grep -q 'DOCKERHUB_SLUG' "$CI" && echo yes || echo no)"
check "CI still publishes to ghcr" "yes" \
      "$(grep -q 'GHCR_SLUG' "$CI" && echo yes || echo no)"


echo "============ NO UNSUFFIXED TAGS ============"
# With three engines in one repository, a bare `:latest` or `:3.0.0` would have
# to mean one arbitrary engine -- whichever merged last. Every version tag
# carries the engine.
check "latest is disabled" "yes" \
      "$(grep -q 'latest=false' "$CI" && echo yes || echo no)"
check "version tags are suffixed with the engine" "yes" \
      "$(grep -q 'suffix=-\${{ env.ENGINE_TAG }}' "$CI" && echo yes || echo no)"

# The bare `:<engine>` tag is what engine.conf's `image=` names and what an
# installed pdfulator pulls, so something must produce it. It was gated on
# {{is_default_branch}} at first, which never fires on a tag build -- so the
# first alpha published six suffixed tags and no `:vivlio` at all.
check "the moving-latest tag is produced" "yes" \
      "$(grep -q 'type=raw,value=\${{ env.ENGINE_TAG }}' "$CI" && echo yes || echo no)"

# ...but only on a release tag. A default-branch push would let any untested
# commit become what every user pulls. Prereleases DO move it during the v3
# development phase -- deliberately, since there is no stable v3 yet and the
# tag would otherwise be frozen at v2 or missing entirely.
check "moving-latest is not gated on the branch" "0" \
      "$(grep -c 'value=\${{ env.ENGINE_TAG }},suffix=,enable={{is_default_branch}}' "$CI")"
check "moving-latest is gated on a release tag" "yes" \
      "$(grep -q 'enable=\${{ steps.channel.outputs.release }}' "$CI" && echo yes || echo no)"
check "the release channel is computed from the ref" "yes" \
      "$(grep -q 'refs/tags/v\*)' "$CI" && echo yes || echo no)"


echo "============ PRERELEASES ARE MARKED ============"
# softprops/action-gh-release does not infer this from the tag name, so
# v3.0.0-alpha1 publishes as a full release and becomes GitHub's "Latest" --
# which is what anyone landing on the releases page is offered first.
check "the release is marked prerelease by tag shape" "yes" \
      "$(grep -q 'prerelease: .*contains(github.ref_name' "$CI" &&
         echo yes || echo no)"


echo "============ THE BAKE FILE ============"
# The default ./Dockerfile does not exist: each engine owns its own, so the
# path must be parameterised by engine.
check "bake picks the Dockerfile by engine" "yes" \
      "$(grep -q 'engines/\${ENGINE}/_nopayload/Dockerfile' "$BAKE" && echo yes || echo no)"
check "ENGINE is a bake variable" "yes" \
      "$(grep -q 'variable "ENGINE"' "$BAKE" && echo yes || echo no)"

# A bake variable is read from the environment. Passing it via `set:` would
# address a Dockerfile ARG instead and leave the default engine building three
# times over -- three identical images under three different tags, which is
# both green and wrong.
check "ENGINE is passed to bake via the environment" "yes" \
      "$(awk '/name: Build/,/Export digest/' "$CI" |
         grep -q 'ENGINE: \${{ matrix.engine }}' && echo yes || echo no)"

# Every engine's Dockerfile must actually exist, or the matrix expands onto a
# path bake cannot resolve.
for e in $ENGINES; do
	check "$e has a Dockerfile" "yes" \
	      "$([ -f "$REPO/engines/$e/_nopayload/Dockerfile" ] && echo yes || echo no)"
done


echo "============ PER-ENGINE ARTIFACTS ============"
# Digests and meta files are shared by name across matrix jobs. Unscoped, the
# three engines' digests land in one artifact and the merge builds a manifest
# list mixing images from different engines.
check "digests are scoped by engine" "yes" \
      "$(grep -q 'digests-\${{ matrix.engine }}-' "$CI" && echo yes || echo no)"
check "the meta bake file is scoped by engine" "yes" \
      "$(grep -q 'bake-meta-\${{ matrix.engine }}' "$CI" && echo yes || echo no)"
check "the build cache is scoped by engine" "yes" \
      "$(grep -q 'scope=build-\${{ matrix.engine }}-' "$CI" && echo yes || echo no)"
check "merge collects only its own engine's digests" "yes" \
      "$(grep -q 'pattern: digests-\${{ matrix.engine }}-\*' "$CI" && echo yes || echo no)"


echo "============ THE TARBALL ============"
# v3 has no root package.json -- a JS engine carries its own, because a
# pandoc-xslt user never meets bun. CI ran `bun install` at the root until
# item 6; it would have failed on every tagged release.
check "no root package.json (v3 layout)" "yes" \
      "$([ ! -f "$REPO/package.json" ] && echo yes || echo no)"
check "CI does not install at the repository root" "0" \
      "$(grep -c '^        run: bun install --frozen-lockfile$' "$CI")"
check "CI installs per engine" "yes" \
      "$(grep -q 'engines/\*/_nopayload/package.json' "$CI" && echo yes || echo no)"

# Every engine declaring a JS runtime needs a lockfile, or the tarball ships
# something the target machine cannot reproduce.
for _c in "$REPO"/engines/*/engine.conf; do
	[ -f "$_c" ] || continue
	grep -q '^needs_runtime=js' "$_c" || continue
	_e=$(basename "${_c%/engine.conf}")
	check "$_e has a lockfile" "yes" \
	      "$([ -f "$REPO/engines/$_e/_nopayload/bun.lock" ] && echo yes || echo no)"
done


echo "============ THE HARD-WON FACTS ============"
# Both of these were learned by losing a release to them. See project-state.

# The release is created with GITHUB_TOKEN, and GitHub suppresses workflow
# triggers from token-created events -- so a `release: published` trigger in
# pages.yaml would never fire and /manifest would silently never refresh.
check "the site rebuild is dispatched explicitly" "yes" \
      "$(grep -q 'gh workflow run pages.yaml' "$CI" && echo yes || echo no)"
check "dist can dispatch a workflow" "yes" \
      "$(awk '/^  dist:/,0' "$CI" | grep -q 'actions: write' && echo yes || echo no)"

# Dispatch accepted is not the same as manifest rebuilt: the step polls for the
# timestamp to move, so a pages.yaml that fails on its own terms is reported
# here rather than looking like success.
check "the dispatch is verified, not assumed" "yes" \
      "$(grep -q 'manifest' "$CI" && grep -q 'GITHUB_STEP_SUMMARY' "$CI" &&
         echo yes || echo no)"

# The branch this development happens on must actually trigger a build.
check "the modular branch triggers CI" "yes" \
      "$(awk '/^  push:/,/^  pull_request:/' "$CI" |
         grep -q '"modular"' && echo yes || echo no)"

echo
[ "$FAIL" -eq 0 ] && echo "ALL EXPECTATIONS MET" || echo "SOME EXPECTATIONS MISSED"
exit $FAIL
