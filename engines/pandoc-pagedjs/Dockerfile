# The pandoc-pagedjs engine's image.
#
# Built from the repository root, like the other container engines:
#
#   docker build -f engines/pandoc-pagedjs/Dockerfile \
#                -t tomgidden/pdfulator:pandoc-pagedjs .
#
# because it needs the shared defaults/ (the fonts) from above the engine
# directory.
#
# node rather than a plain Debian base because Paged.js is the awkward
# dependency: pandoc and Chromium are both good Debian packages, and
# pagedjs-cli is not packaged at all. Starting from node makes the hard one
# easy and the easy ones no harder -- v1's reasoning, and still right.
FROM node:slim

LABEL maintainer="tom@gidden.net"
LABEL org.opencontainers.image.title="PDFulator (pandoc-pagedjs engine)"
LABEL org.opencontainers.image.description="Markdown to PDF: Pandoc, Paged.js, Chromium"
LABEL org.opencontainers.image.authors="Tom Gidden <tom@gidden.net>"
LABEL org.opencontainers.image.source="https://github.com/tomgidden/pdfulator"
LABEL org.opencontainers.image.license="MIT"

# --no-install-recommends matters more than usual here. Chromium recommends a
# printer-configuration GUI stack (system-config-printer-common -> python3-smbc
# -> libsmbclient0 -> samba-libs -> libldb2 -> liblmdb0) that a headless
# renderer never touches; in v1 it accounted for most of the image's critical
# CVEs and around 400MB. ca-certificates is therefore explicit, having
# previously arrived as a recommend.
#
# Dropped from v1's list: zsh and inotify-tools, both of which existed only for
# the entrypoint. Watch mode is the wrapper's now and runs on the host, so
# nothing in here needs to watch a file, and nothing needs a shell beyond
# /bin/sh.
#
# Also dropped: the Google Chrome apt repository. v1 added the signing key and
# source list and then installed Debian's own `chromium` anyway, so the repo
# contributed a key, a fetch and a second `apt-get update` to no effect.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      chromium \
      pandoc \
 && rm -rf /var/lib/apt/lists/*

# Paged.js drives Chromium through puppeteer, which must be told to use the
# packaged browser rather than downloading its own at install time.
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV CHROME_PATH=/usr/bin/chromium

# --ignore-scripts, since the postinstall scripts here exist to fetch a browser
# that is already present.
RUN npm install -g --unsafe-perm --ignore-scripts pagedjs-cli

# The shared assets: the fonts, which every engine's stylesheet uses. The
# engine's own template, filter and stylesheet come next -- those are not
# shared, and the reason is worth stating: defaults/article.tmpl is a
# *Mustache* template belonging to the vivlio engine, while this pipeline needs
# a *pandoc* template. Same name, same ancestry, different syntax; putting both
# in defaults/ would be a name collision waiting to be found by whoever edits
# the wrong one.
COPY defaults /defaults
COPY engines/pandoc-pagedjs/article.tmpl \
     engines/pandoc-pagedjs/metadata.lua \
     engines/pandoc-pagedjs/print.css \
     /engine/

# The built-in theme, so the image works with no mounts at all. A user theme
# is mounted over /theme by the engine's convert.
COPY theme /theme

# Where the wrapper mounts things, plus the scratch directory the conversion
# works in.
#
# /work is mode 1777 -- world-writable with the sticky bit, as /tmp is -- and
# not merely owned by `node`. The wrapper passes `--user <caller's uid>` so the
# PDF is not left owned by someone else, and that uid is in no /etc/passwd
# here: it owns nothing, belongs to no group that owns anything, and a
# `chown node:node /work` leaves it unable to write. The failure is
#
#   mktemp: failed to create directory via template '/work/pdfulator.XXXXXX'
#
# after the mounts are all correct, and it cannot happen in bare `docker run`
# mode, which runs as `node` -- so only the wrapper path meets it.
RUN mkdir -p /in /out /work \
 && chown node:node /in /out \
 && chmod 1777 /work

USER node
WORKDIR /work

COPY --chmod=755 engines/pandoc-pagedjs/render /usr/local/bin/render

# The engine contract, verbatim: <input|-> <output|-> <theme-dir>. Defaulting
# to stdin -> stdout with the built-in theme is what makes the image usable
# with no wrapper and no installer:
#
#   docker run --rm --init -i tomgidden/pdfulator:pandoc-pagedjs < in.md > out.pdf
ENTRYPOINT ["/usr/local/bin/render"]
CMD ["-", "-", "/theme"]
