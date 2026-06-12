TAG    = tomgidden/pdfulator
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
		--platform linux/arm/v7,linux/arm64/v8,linux/amd64 \
		--tag $(TAG) .

# Local install — extracts assets to ~/.local/share/pdfulator/

install: install-deps install-assets install-bin

install-deps:
	bun install

install-assets:
	mkdir -p $(SHARE)/defaults $(SHARE)/themes
	cp -r defaults/. $(SHARE)/defaults/
	@echo "Assets installed to $(SHARE)/defaults/"
	@echo "Place themes in $(SHARE)/themes/<theme-name>/"

install-bin:
	mkdir -p $(PREFIX)/bin
	install -m 755 pdfulator.js $(PREFIX)/bin/pdfulator
	@echo "Installed to $(PREFIX)/bin/pdfulator"

# Self-extracting bundle
# Creates a single 'pdfulator' shell script with assets embedded as base64.
# Requires: bun install already run (node_modules present)

BUNDLE_FILES = pdfulator.js defaults package.json

BUNDLE_NAME=pdfulator

bundle: $(BUNDLE_NAME) $(BUNDLE_FILES)

install-bundle: bundle
	cp $(BUNDLE_NAME) ~/.local/bin/

$(BUNDLE_NAME): bun.lock
	@echo "Building self-extracting bundle..."
	@TMPBUNDLE=$$(mktemp -d) && \
	cp pdfulator.js $$TMPBUNDLE/ && \
	cp package.json $$TMPBUNDLE/ && \
	cp bun.lock $$TMPBUNDLE/ && \
	cp -r defaults $$TMPBUNDLE/ && \
	cp -r theme $$TMPBUNDLE/ && \
	ARCHIVE=$$(cd $$TMPBUNDLE && tar czf - . | base64) && \
	rm -rf $$TMPBUNDLE && \
	{ printf '%s\n' \
		'#!/bin/sh' \
		'# pdfulator self-extracting bundle' \
		'set -e' \
		'PDFULATOR_HOME="$${PDFULATOR_HOME:-$$HOME/.local/share/pdfulator}"' \
		'if [ ! -f "$$PDFULATOR_HOME/.installed" ]; then' \
		'  echo "Installing pdfulator to $$PDFULATOR_HOME..." >&2' \
		'  mkdir -p "$$PDFULATOR_HOME"' \
		'  SKIP=$$(awk "/^__ARCHIVE_BELOW__$$/{print NR+1; exit}" "$$0")' \
		'  tail -n +$$SKIP "$$0" | base64 -d | tar -xzf - -C "$$PDFULATOR_HOME"' \
		'  (cd "$$PDFULATOR_HOME" && bun install --frozen-lockfile) >&2' \
		'  touch "$$PDFULATOR_HOME/.installed"' \
		'  echo "Done." >&2' \
		'fi' \
		'exec bun run "$$PDFULATOR_HOME/pdfulator.js" "$$@"' \
		'__ARCHIVE_BELOW__'; \
	printf '%s\n' "$$ARCHIVE"; } > $(BUNDLE_NAME) && \
	chmod +x $(BUNDLE_NAME) && \
	echo "Bundle written to $(BUNDLE_NAME) ($$(wc -c < $(BUNDLE_NAME)) bytes)"

bun.lock: package.json
	bun install

.PHONY: all watch docker-watch build release install install-deps install-assets install-bin bundle

