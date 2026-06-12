FROM oven/bun:slim

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

# Install npm dependencies
WORKDIR /app
COPY package.json ./
RUN bun install --frozen-lockfile

# Copy assets and script
COPY defaults ./defaults
COPY theme    ./theme
COPY pdfulator.js ./

# Input directory (mount user files here)
RUN mkdir /in && chown bun:bun /in

USER bun

ENTRYPOINT ["bun", "run", "/app/pdfulator.js"]
