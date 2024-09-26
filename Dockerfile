# node used for PagedJS, as it's harder to install than everything else.
# Other major dependencies work well from packages.
FROM node:slim

LABEL maintainer="tom@gidden.net"
LABEL org.opencontainers.image.title="PDFulator"
LABEL org.opencontainers.image.description="Markdown to PDF converter, using Pandoc, PagedJS and Chromium, packaged as a Docker image"
LABEL org.opencontainers.image.authors="Tom Gidden <tom@gidden.net>"
LABEL org.opencontainers.image.source="https://github.com/tomgidden/pdfulator"
LABEL org.opencontainers.image.license="MIT"

# Install Chromium, Pandoc and a couple of developer conveniences.
# Remove package files afterwards to minimise footprint
RUN <<EOF
apt-get update
apt-get install -y wget gnupg
wget -q -O /etc/apt/trusted.gpg.d/linux_signing_key.asc https://dl-ssl.google.com/linux/linux_signing_key.pub
echo "deb http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google.list

apt-get update
apt-get install -y chromium bash pandoc inotify-tools zsh
rm -rf /var/lib/apt/lists/*
EOF

# We'll use our own chromium from the package
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# Setup Paged.js
RUN <<EOF
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
export HOME=/home/node

cd $HOME

npm install -g --unsafe-perm=true --allow-root --ignore-scripts pagedjs-cli

chown -R node:node /home/node
EOF

# Setup folders
RUN <<EOF
mkdir /in
mkdir /work
chown -R node:node /in /work
EOF

# Copy out-of-the-box assets
COPY defaults /defaults
COPY theme /theme
COPY README.md /defaults/README.md

USER node

WORKDIR /

# Copy the main launch script
COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
