PREFIX = $(HOME)/.local
SHARE  = $(PREFIX)/share/pdfulator

# Which container engine the docker- targets use, and which image `make build`
# builds. Override on the command line: `make build DOCKER_ENGINE=pandoc-pagedjs`.
#
# The tag comes out of the engine's own engine.conf rather than being repeated
# here -- two places to change a tag is one place to forget.
DOCKER_ENGINE = vivlio-docker
TAG = $(shell sed -n 's/^image=//p' engines/$(DOCKER_ENGINE)/engine.conf | head -1)

# Every container engine, for `make build-all`. Discovered rather than listed,
# so a new engine directory is picked up by existing it.
DOCKER_ENGINES = $(shell grep -l '^needs_docker=yes' engines/*/engine.conf | \
                   sed 's|engines/||; s|/engine.conf||')

# THEME= and DEBUG= become wrapper switches rather than docker options. The old
# rules bolted `-v $(THEME):/app/theme` onto the container directly, which the
# local (non-docker) rules could not use at all -- so `make THEME=x foo.pdf`
# and `make THEME=x docker-foo.pdf` meant different things. Going through
# --theme makes them one thing, and theme resolution stays in lib/theme.sh
# where the by-name lookup lives.
ifdef THEME
SWITCHES += --theme $(THEME)
endif

ifdef DEBUG
SWITCHES += -d
endif

PDFS = $(patsubst %.md,%.pdf,$(wildcard *.md))

# Local conversion (requires bun + Chromium on host)

all: $(PDFS)

# Through the wrapper, not an engine: the wrapper is what plans jobs and
# resolves themes, so `make foo.pdf` and `pdfulator foo.md` are the same path.
%.pdf: %.md
	./pdfulator.sh $(SWITCHES) $< $@

watch:
	./pdfulator.sh --watch $(SWITCHES) .

# Docker conversion
#
# Through the wrapper with the container engine selected, not by invoking
# docker here. The wrapper is what plans jobs, resolves themes and builds the
# mounts, so `make docker-foo.pdf` and `pdfulator --engine vivlio-docker
# foo.md` are one code path -- which is the whole point of the refactor. The
# old rule assembled a sidecar onto stdin with shell and make conditionals,
# duplicating logic the engine already has and getting it subtly different.

docker-%.pdf: %.md
	./pdfulator.sh --engine $(DOCKER_ENGINE) $(SWITCHES) $< $@

docker-watch:
	./pdfulator.sh --engine $(DOCKER_ENGINE) --watch $(SWITCHES) .

# Build & publish the engine's image
#
# Built from the repository root with -f, because the image needs the vivlio
# engine's main.js and lockfile plus themes/, all of
# which live above the engine directory.

build:
	docker build -f engines/$(DOCKER_ENGINE)/Dockerfile -t $(TAG) .

# Each container engine's image, one after another. Step 9 turns this into a
# CI matrix; this is the local equivalent.
build-all:
	@for e in $(DOCKER_ENGINES); do \
		tag=$$(sed -n 's/^image=//p' engines/$$e/engine.conf | head -1); \
		echo "==> $$e ($$tag)"; \
		docker build -f engines/$$e/Dockerfile -t "$$tag" . || exit 1; \
	done

release:
	docker buildx build --push \
		--platform linux/arm64,linux/amd64 \
		-f engines/$(DOCKER_ENGINE)/Dockerfile \
		--tag $(TAG) .

# Distribution tarball
#
# What CI publishes and install.sh downloads: the application, the wrapper
# (named `pdfulator`, since that's what it becomes once installed), and the
# lockfile that lets the target machine run `bun install --frozen-lockfile`.
# Deliberately no node_modules -- those are platform-specific and installed
# on arrival.

DIST      = pdfulator.tar.gz
DIST_TOP  = themes templates lib engines
# Expanded for dependency tracking only; the copy uses DIST_TOP so that
# directories arrive as directories rather than a flattened heap of files.
#
# engines/ is pruned of node_modules: an engine's dependencies are as
# platform-specific as the top-level ones and are installed on arrival from the
# engine's own bun.lock, which does ship. (Step 5 of the modular plan splits
# these into per-engine tarballs so a user downloads only the engines they use;
# until then they ride along in the one tarball.)
DIST_SRC  = $(shell find themes templates lib -type f) \
            $(shell find engines -type f -not -path '*/node_modules/*')

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
	@# cp -R brings an engine's installed node_modules with it; those are
	@# platform-specific and are reinstalled on arrival, exactly as the
	@# top-level ones are. Pruning after the copy keeps DIST_TOP readable.
	@find .dist/engines -name node_modules -type d -prune -exec rm -rf {} +
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

# Install straight from the working tree, without building a tarball at all.
# install-local is the faithful one -- it installs exactly the bytes a release
# would ship. This is the fast one, for when the packing step is what's in the
# way: editing a lib/ file and wanting the installed command to have it.
install-source:
	PDFULATOR_SOURCE=$(CURDIR) ./install.sh

# The common layer's matrices: POSIX sh, no browser, no runtime, no tarball, a
# second or two all told. Run with `sh` rather than `bash` deliberately -- they
# test code that ships to whatever /bin/sh a user has, and this project once
# shipped a dash bug precisely by testing only under bash on macOS.
test-lib:
	sh tests/planmatrix.sh
	sh tests/themematrix.sh
	sh tests/templatematrix.sh
	sh tests/stylingmatrix.sh
	sh tests/fontmatrix.sh
	sh tests/stagematrix.sh
	sh tests/sourcematrix.sh
	sh tests/browsermatrix.sh
	sh tests/watchmatrix.sh
	sh tests/enginematrix.sh
	sh tests/dockermatrix.sh
	sh tests/pandocmatrix.sh
	sh tests/xsltmatrix.sh
	sh tests/cimatrix.sh

# Argument-handling matrices. These need a CHROME_PATH (or a pinned browser);
# wrapmatrix additionally needs the tarball, since it installs what it tests.
test: test-lib $(DIST)
	sh tests/vivliomatrix.sh
	bash tests/argmatrix.sh
	bash tests/wrapmatrix.sh
	bash tests/uninstallmatrix.sh
	bash tests/updatematrix.sh
	@$(MAKE) -s dist >/dev/null   # updatematrix leaves a versioned tarball behind

clean:
	rm -rf .dist .version $(DIST) $(DIST).sha256

.PHONY: all watch docker-watch build build-all release dist install-local install-source test test-lib clean

