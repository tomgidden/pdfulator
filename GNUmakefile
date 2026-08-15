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

# What `pdfulator --version` reports and `--update` compares against. CI
# overrides this with the tag being built (VERSION=$(github.ref_name)); a local
# build gets `git describe`, whose -dirty suffix is what stops --update from
# offering to overwrite a work-in-progress with a release.
VERSION  ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

# The version isn't a file, so make can't see it change: building v2.0.0 and
# then v2.1.0 from an unchanged tree would otherwise silently republish the
# first one. .version records what the existing tarball was stamped with; if
# that no longer matches, the tarball is stale by definition, so drop it before
# make evaluates the rule below. (Rewriting .version as a prerequisite of $(DIST)
# doesn't work: make stats it before the recipe runs.)
$(shell [ -f .version ] && [ "$$(cat .version)" = "$(VERSION)" ] || \
        rm -f $(DIST) $(DIST).sha256)

dist: $(DIST)

# install.sh ships inside the tarball as well as beside it: --update re-runs it
# rather than reimplementing download, verify, stage and swap.
$(DIST): pdfulator.sh install.sh $(DIST_SRC)
	@rm -rf .dist && mkdir -p .dist
	@cp -R $(DIST_TOP) .dist/
	@cp pdfulator.sh .dist/pdfulator
	@cp install.sh .dist/install.sh
	@chmod +x .dist/pdfulator .dist/install.sh
	@echo "$(VERSION)" > .dist/VERSION
	tar czf $@ -C .dist .
	@rm -rf .dist
	@echo "$(VERSION)" > .version
	@echo "$(DIST) written, version $(VERSION) ($$(wc -c < $(DIST) | tr -d ' ') bytes)"

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

# Argument-handling matrices. Both need a CHROME_PATH (or a pinned browser);
# wrapmatrix additionally needs the tarball, since it installs what it tests.
test: $(DIST)
	bash tests/argmatrix.sh
	bash tests/wrapmatrix.sh
	bash tests/uninstallmatrix.sh
	bash tests/updatematrix.sh
	@$(MAKE) -s dist >/dev/null   # updatematrix leaves a versioned tarball behind

clean:
	rm -rf .dist .version $(DIST) $(DIST).sha256

.PHONY: all watch docker-watch build release dist install-local test clean

