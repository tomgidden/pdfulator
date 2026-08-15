TAG    = tomgidden/pdfulator:2
PREFIX = $(HOME)/.local
SHARE  = $(PREFIX)/share/pdfulator

EXTRA_DOCKER_OPTS ?=

ifdef THEME
EXTRA_DOCKER_OPTS += -v $(abspath $(THEME)):/app/theme
endif

ifdef DEBUG
SWITCHES  += -d
DEBUG_OPTS = -v $(abspath ./pdfulator.js):/app/pdfulator.js \
             -v $(abspath ./defaults):/app/defaults
endif

PDFS = $(patsubst %.md,%.pdf,$(wildcard *.md))

# Local conversion (requires bun + Chromium on host)

all: $(PDFS)

%.pdf: %.md
	bun run pdfulator.js $(SWITCHES) $< $@

watch:
	bun run pdfulator.js --watch $(SWITCHES) .

# Docker conversion

docker-%.pdf: %.md
	($(if $(wildcard $*.yaml),\
		echo "---" && cat $*.yaml && printf "\n..." && cat $*.md,\
		$(if $(wildcard $*.yml),\
			echo "---" && cat $*.yml && printf "\n..." && cat $*.md,\
			cat $*.md \
		) \
	)) | docker run --rm --init -i \
		$(EXTRA_DOCKER_OPTS) $(DEBUG_OPTS) \
		$(TAG) $(SWITCHES) - > $@

docker-watch:
	docker run --rm --init -it \
		$(EXTRA_DOCKER_OPTS) $(DEBUG_OPTS) \
		-v $(abspath .):/in \
		$(TAG) $(SWITCHES) --watch

# Build & publish Docker image

build:
	docker build -t $(TAG) .

release:
	docker buildx build --push \
		--platform linux/arm64,linux/amd64 \
		--tag $(TAG) .

# Distribution tarball
#
# What CI publishes and install.sh downloads: the application, the wrapper
# (named `pdfulator`, since that's what it becomes once installed), and the
# lockfile that lets the target machine run `bun install --frozen-lockfile`.
# Deliberately no node_modules -- those are platform-specific and installed
# on arrival.

DIST      = pdfulator.tar.gz
DIST_TOP  = pdfulator.js package.json bun.lock defaults theme
# Expanded for dependency tracking only; the copy uses DIST_TOP so that
# directories arrive as directories rather than a flattened heap of files.
DIST_SRC  = pdfulator.js package.json bun.lock \
            $(shell find defaults theme -type f)

dist: $(DIST)

$(DIST): pdfulator.sh $(DIST_SRC)
	@rm -rf .dist && mkdir -p .dist
	@cp -R $(DIST_TOP) .dist/
	@cp pdfulator.sh .dist/pdfulator
	@chmod +x .dist/pdfulator
	tar czf $@ -C .dist .
	@rm -rf .dist
	@echo "$(DIST) written ($$(wc -c < $(DIST) | tr -d ' ') bytes)"

# The checksum install.sh verifies against.
$(DIST).sha256: $(DIST)
	@(command -v sha256sum >/dev/null && sha256sum $(DIST) || shasum -a 256 $(DIST)) > $@
	@cat $@

# Install straight from a checkout, without going through a release. Goes via
# install.sh so a local install is identical to a downloaded one -- manifest
# and all, which is what makes --uninstall work afterwards.
install-local: $(DIST) $(DIST).sha256
	PDFULATOR_TARBALL=$(abspath $(DIST)) ./install.sh

bun.lock: package.json
	bun install

clean:
	rm -rf .dist $(DIST) $(DIST).sha256

.PHONY: all watch docker-watch build release dist install-local clean

