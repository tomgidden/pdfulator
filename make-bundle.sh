#!/usr/bin/env bash
#
# make-bundle.sh — build the self-extracting `pdfulator` script.
#
# Assembly only: the loader logic lives in pdfulator.sh, which is concatenated
# with an __ARCHIVE_BELOW__ marker and a base64 tarball of the app. On first run
# the result unpacks itself into $PDFULATOR_HOME, obtains bun and the npm deps,
# then execs pdfulator.js. Later runs go straight to the exec.
#
# Usage: make-bundle.sh [output-name]      (default: pdfulator)

set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_NAME="${1:-pdfulator}"
LOADER=pdfulator.sh

# Everything that ends up inside the archive. Directories are copied
# recursively; the lockfile is what makes `bun install --frozen-lockfile` work
# on the target machine.
PAYLOAD=(pdfulator.js package.json bun.lock defaults theme)

for f in "$LOADER" "${PAYLOAD[@]}"; do
	[ -e "$f" ] || { echo "make-bundle: missing '$f'" >&2; exit 1; }
done

# A broken loader would only fail on the user's machine, so check it here.
sh -n "$LOADER" || { echo "make-bundle: $LOADER has a syntax error" >&2; exit 1; }

echo "Building self-extracting bundle..." >&2

# Stage the payload so the tarball has clean top-level paths, and make sure it
# goes away however we exit.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

cp -R "${PAYLOAD[@]}" "$staging/"

archive=$(cd "$staging" && tar czf - . | base64)

# loader + marker + payload. The loader finds the marker by scanning itself, so
# the exact spelling here has to match the awk pattern inside pdfulator.sh.
{
	cat "$LOADER"
	printf '__ARCHIVE_BELOW__\n'
	printf '%s\n' "$archive"
} > "$BUNDLE_NAME"

chmod +x "$BUNDLE_NAME"

echo "Bundle written to $BUNDLE_NAME ($(wc -c < "$BUNDLE_NAME" | tr -d ' ') bytes)" >&2
