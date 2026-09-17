# The pandoc-pagedjs engine's image.
#
# Built from the repository root, like the other container engines:
#
#   docker build -f engines/pandoc-pagedjs/Dockerfile \
#                -t tomgidden/pdfulator:pandoc-pagedjs .
#
# because it needs the themes/ directory from above the engine
# directory.
#
# Three upstream images, each supplying the one thing it is good at, rather
# than one base and an apt list.
#
# v1 started from node:slim and apt-installed chromium and pandoc, on the
# reasoning that pagedjs-cli is the awkward dependency and the other two are
# good Debian packages. They are -- but Debian's `chromium` drags in a GPU
# stack a headless PDF pipeline never touches (libllvm19 124MB,
# mesa-libgallium 41MB, on top of chromium's own 307MB), and that made the
# browser the expensive half of an image built to make pagedjs-cli easy.
#
# So the browser is the base now and the other two are copied onto it:
#
#   chromedp/headless-shell  chrome-headless-shell on Debian trixie, no GPU
#                            stack. The same browser the BUNDLED engine
#                            downloads, so the two no longer merely both render.
#   pandoc/minimal:static    one statically-linked binary, no runtime deps.
#   node:slim                node and npm, for pagedjs-cli.
#
# All three are multi-arch (linux/amd64 and linux/arm64), which is a hard
# requirement: CI builds both.
FROM pandoc/minimal:latest-static AS pandoc
FROM node:slim AS node

FROM chromedp/headless-shell:latest

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
# Two apt packages, and both are needed by something copied in rather than by
# this image's own base: ca-certificates so npm can reach the registry, and
# libatomic1 because node links against libatomic.so.1, which chromedp's image
# does not ship. Without it `node --version` fails with a shared-library error
# and the npm install below exits 127.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libatomic1 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=pandoc /usr/local/bin/pandoc /usr/local/bin/pandoc
COPY --from=node   /usr/local/bin/node   /usr/local/bin/node
COPY --from=node   /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

# Paged.js drives the browser through puppeteer, which must be told to use the
# one that is here rather than downloading its own at install time. The path is
# chromedp's, not Debian's.
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/headless-shell/headless-shell
ENV CHROME_PATH=/headless-shell/headless-shell

# --ignore-scripts, since the postinstall scripts here exist to fetch a browser
# that is already present.
RUN npm install -g --unsafe-perm --ignore-scripts pagedjs-cli

# The engine's own filter, and the template it falls back to.
#
# No fonts and no stylesheet: both now come from the payload the wrapper stages
# and mounts, which is what lets one theme dress this engine and the browser
# ones alike.
#
# The template comes from templates/html-pandoc-pagedjs rather than from this
# engine's own directory, because it is a property of the *ecosystem* -- HTML
# filled by pandoc's $var$ syntax -- and not of this engine alone. The vivlio
# engines' template has the same ancestry and nearly the same markup but
# Mustache placeholders, and the two being interchangeable by filename is
# exactly what produced a PDF with template markup printed in it.
COPY templates/html-pandoc-pagedjs/template.html.pandoc /engine/template.html.pandoc
COPY engines/pandoc-pagedjs/_nopayload/metadata.lua        /engine/metadata.lua

# The fallback payload, for a bare `docker run` that mounts nothing. Normally
# the wrapper stages a payload and mounts it over this.
#
# It is themes/default rather than a real payload: the wrapper's generated
# files (print.css, fonts.css, logo.css) are not here, which is why `render`
# links only the stylesheets it can actually find.
#
# themes/default no longer carries a template of its own -- that moved to
# templates/html-mustache-vivlio -- so this is stylesheets and theme.conf only,
# and there is no longer any way for a Mustache template to arrive here under a
# name pandoc would read.
COPY themes/default /payload

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
# chromedp/headless-shell runs as root and ships no unprivileged user, where
# node:slim provided one. A `node` user is created here rather than dropping
# the USER line: an engine writing into a bind-mounted /out as root leaves
# root-owned files on the user's host.
RUN groupadd -r node && useradd -r -g node node \
 && mkdir -p /in /out /work \
 && chown node:node /in /out \
 && chmod 1777 /work

USER node
WORKDIR /work

COPY --chmod=755 engines/pandoc-pagedjs/_nopayload/render /usr/local/bin/render

# The engine contract, verbatim: <input|-> <output|-> <payload-dir>. Defaulting
# to stdin -> stdout with the built-in fallback is what makes the image usable
# with no wrapper and no installer:
#
#   docker run --rm --init -i tomgidden/pdfulator:pandoc-pagedjs < in.md > out.pdf
ENTRYPOINT ["/usr/local/bin/render"]
CMD ["-", "-", "/payload"]
