# The vivlio-docker engine's image.
#
# Built from the repository root, not from this directory:
#
#   docker build -f engines/vivlio-docker/Dockerfile -t tomgidden/pdfulator:vivlio .
#
# because the image needs three things that live above it -- the vivlio
# engine's main.js and lockfile, and the built-in theme/ and themes/. A
# Dockerfile beside its own context would mean duplicating those into this
# directory, and a duplicated theme is one that silently drifts.
#
# What is deliberately NOT in here: the wrapper, lib/, install.sh. The image is
# an *engine*, and an engine only converts. `docker run` on it is the engine
# contract, not a second CLI -- which is what makes the bare-container mode and
# the wrapper-driven mode the same code path rather than two that must agree.

FROM oven/bun:1

LABEL maintainer="tom@gidden.net"
LABEL org.opencontainers.image.title="PDFulator (vivlio engine)"
LABEL org.opencontainers.image.description="Markdown to PDF: markdown-it, Vivliostyle, Chromium"
LABEL org.opencontainers.image.authors="Tom Gidden <tom@gidden.net>"
LABEL org.opencontainers.image.source="https://github.com/tomgidden/pdfulator"
LABEL org.opencontainers.image.license="MIT"

# Chromium is the renderer. inotify-tools is not needed here and is not
# installed: watch mode belongs to the wrapper, which runs on the host and
# starts a container per conversion -- so the thing watching the files is
# outside, watching the host's own directory. The old image shipped
# inotify-tools because it had its own --watch; that CLI is gone.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium \
 && rm -rf /var/lib/apt/lists/*

# Tell puppeteer-core where Chromium is; never let it download its own.
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV CHROME_PATH=/usr/bin/chromium

# The engine's dependencies, from the vivlio engine's own lockfile -- the same
# file the bundled engine installs from, so the two cannot drift.
WORKDIR /app
COPY engines/vivlio/package.json engines/vivlio/bun.lock ./
RUN bun install --frozen-lockfile

# The built-in theme, then the engine itself.
#
# There is no defaults/ any more: the stylesheet, template and fonts that lived
# there are themes now, and the wrapper stages a theme into one directory and
# mounts it. An image carrying its own copy would be a second opinion about
# what a document should look like.
# themes/ so a `--theme classic` works inside the image too; theme/ is the
# fallback for a run that supplies none, and is themes/default.
COPY themes         ./themes
COPY themes/default ./theme
COPY engines/vivlio/main.js ./

# Where the wrapper mounts things. Created here, and owned by the runtime user,
# so that a container writing an output file into /out can do so without the
# mount having to be world-writable on the host.
#
#   /in     the document (read-only when the wrapper mounts it)
#   /out    where the PDF goes
#   /theme  the theme directory, when it isn't the built-in one
RUN mkdir -p /in /out /theme && chown bun:bun /in /out /theme

USER bun

# The engine contract, verbatim: <input|-> <output|-> <theme-dir>.
#
# The default arguments are what makes the image usable with no wrapper and no
# installer at all:
#
#   docker run --rm --init -i tomgidden/pdfulator:vivlio < in.md > out.pdf
#
# stdin to stdout with the built-in theme. The wrapper overrides all three with
# mounted paths; a person at a terminal overrides none.
ENTRYPOINT ["bun", "run", "/app/main.js"]
CMD ["-", "-", "/app/theme"]
