# The pandoc-xslt engine's image.
#
#   docker build -f engines/pandoc-xslt/Dockerfile \
#                -t tomgidden/pdfulator:pandoc-xslt .
#
# Built from the repository root for consistency with the other engines, though
# this one needs nothing from above its own directory: the stylesheets are its
# own, and its fonts arrive at run time in the theme the wrapper stages and
# mounts, exactly as they do for the browser engines.
FROM debian:12-slim

LABEL maintainer="tom@gidden.net"
LABEL org.opencontainers.image.title="PDFulator (pandoc-xslt engine, deprecated)"
LABEL org.opencontainers.image.description="Markdown to PDF: Pandoc, DocBook 5, XSL-FO, Apache FOP"
LABEL org.opencontainers.image.authors="Tom Gidden <tom@gidden.net>"
LABEL org.opencontainers.image.source="https://github.com/tomgidden/pdfulator"
LABEL org.opencontainers.image.license="MIT"

# pandoc parses, xsltproc transforms, the docbook packages supply the
# stylesheets and the catalog that resolves their URLs offline, and the JRE
# runs FOP.
#
# default-jre-headless, not a full JDK: FOP ships compiled and needs only a
# runtime. Headless because there is no display and the AWT classes Batik
# touches work fine without one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      default-jre-headless \
      docbook-xsl \
      docbook5-xml \
      libxml2-utils \
      pandoc \
      perl \
      xsltproc \
 && rm -rf /var/lib/apt/lists/*

# Apache FOP, pinned.
#
# NOT Debian's `fop` package, which is 2.8. This engine is deprecated and will
# not be revisited, so it is better to freeze it at the last release that was
# tested against this XSLT than to let a distro upgrade silently change the
# output of a pipeline nobody is maintaining. 2.11 is the current release
# (May 2025) and the last this stylesheet was verified against.
#
# archive.apache.org rather than the mirror system: mirrors drop old releases,
# and the 2015 Dockerfile's eu.apache.org URL is dead for exactly that reason.
# The archive is the permanent home and keeps everything back to 0.20.5.
#
# The checksum is Apache's own published SHA-512, verified against the download
# rather than computed from it. Vendoring the tarball into git was considered
# and rejected: 17MB of binary in every clone, forever, to save a fetch at
# build time from a URL that has been stable for a decade.
#
# Apache License 2.0 throughout, FOP and its bundled Batik/PDFBox/commons jars
# alike, so redistribution in this image is unencumbered.
ARG FOP_VERSION=2.11
ARG FOP_SHA512=47f26517cdb514415e584a804763a5b81b8f178279d921c73b9c0a6a179f3cfc13ac2071a2085277158b336ad9c84e40a86358aa235da82a8f7ef4e83b994b16
RUN set -eu; \
    url="https://archive.apache.org/dist/xmlgraphics/fop/binaries/fop-${FOP_VERSION}-bin.tar.gz"; \
    curl -fsSL -o /tmp/fop.tar.gz "$url"; \
    echo "${FOP_SHA512}  /tmp/fop.tar.gz" | sha512sum -c -; \
    mkdir -p /opt; \
    tar xzf /tmp/fop.tar.gz -C /opt; \
    rm /tmp/fop.tar.gz; \
    ln -s "/opt/fop-${FOP_VERSION}/fop/fop" /usr/local/bin/fop; \
    fop -version

# The engine's assets: the stylesheets, the fonts they name, the pandoc
# template that produces DocBook, and the lua filter that fills in the year.
# All the engine's own. No fonts among them: those belong to the theme, which
# is mounted, and the wrapper generates the FOP configuration that names them
# (see fonts_fop_xconf and the fop-fonts.xconf that `render` prefers).
COPY engines/pandoc-xslt/xsl        /engine/xsl
COPY engines/pandoc-xslt/metadata.lua /engine/metadata.lua

# The built-in theme, so the image works with no mounts at all.
# The fallback theme, for a run that supplies none. Normally the wrapper
# stages one and mounts it over this.
COPY themes/default /theme

# /work is 1777 rather than owned by a user: the wrapper passes the caller's
# uid, which exists in no /etc/passwd here and so cannot write a directory
# chowned to anyone else. That failure -- "mktemp: failed to create directory"
# -- is invisible from bare `docker run`, which uses the image's own user.
RUN mkdir -p /in /out /work && chmod 1777 /work

COPY --chmod=755 engines/pandoc-xslt/render /usr/local/bin/render

WORKDIR /work

# The engine contract: <input|-> <output|-> <theme-dir>, defaulting to
# stdin -> stdout with the built-in theme, so the image is usable bare:
#
#   docker run --rm --init -i tomgidden/pdfulator:pandoc-xslt < in.md > out.pdf
ENTRYPOINT ["/usr/local/bin/render"]
CMD ["-", "-", "/theme"]
