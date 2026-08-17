FROM oven/bun:1

LABEL maintainer="tom@gidden.net"
LABEL org.opencontainers.image.title="PDFulator"
LABEL org.opencontainers.image.description="Markdown to PDF converter using Bun, Vivliostyle and Chromium"
LABEL org.opencontainers.image.authors="Tom Gidden <tom@gidden.net>"
LABEL org.opencontainers.image.source="https://github.com/tomgidden/pdfulator"
LABEL org.opencontainers.image.license="MIT"

# Install Chromium and inotify-tools (watch mode)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium \
      inotify-tools \
 && rm -rf /var/lib/apt/lists/*

# Tell puppeteer-core where Chromium is; skip any automatic download
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV CHROME_PATH=/usr/bin/chromium

# The engine's dependencies, not the distribution's: an engine owns what makes
# it that engine, and this image is the vivlio engine plus a browser.
WORKDIR /app
COPY engines/vivlio/package.json engines/vivlio/bun.lock ./
RUN bun install --frozen-lockfile

# Shared assets, then the engine itself. defaults/ and theme/ sit above the
# engine because every engine renders the same document; $PDFULATOR_DEFAULTS
# is what points main.js at them from here.
COPY defaults ./defaults
COPY theme    ./theme
COPY engines/vivlio/main.js ./

ENV PDFULATOR_DEFAULTS=/app/defaults

# Input directory (mount user files here)
RUN mkdir /in && chown bun:bun /in

USER bun

# The engine contract, not the old CLI: <input|-> <output|-> <theme-dir>. The
# default is stdin to stdout with the built-in theme, which is what
#   docker run --rm --init -i tomgidden/pdfulator < in.md > out.pdf
# needs; step 6 of the modular plan replaces this with the vivlio-docker
# engine's own entrypoint, which also accepts mounted directories.
ENTRYPOINT ["bun", "run", "/app/main.js"]
CMD ["-", "-", "/app/theme"]
