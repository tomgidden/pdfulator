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

# Self-extracting bundle
#
# The only install route: a single 'pdfulator' script with assets embedded as
# base64, which unpacks itself to $PDFULATOR_HOME on first run. (Docker aside,
# this is how pdfulator is meant to be installed -- there is deliberately no
# "copy pdfulator.js into ~/.local/bin" mode, since the script needs its
# node_modules and defaults alongside it.)

BUNDLE_NAME  = pdfulator
BUNDLE_FILES = pdfulator.js package.json bun.lock \
               $(shell find defaults theme -type f)

bundle: $(BUNDLE_NAME)

install-bundle: bundle
	mkdir -p $(PREFIX)/bin
	install -m 755 $(BUNDLE_NAME) $(PREFIX)/bin/
	@echo "Installed to $(PREFIX)/bin/$(BUNDLE_NAME)"

$(BUNDLE_NAME): make-bundle.sh pdfulator.sh $(BUNDLE_FILES)
	./make-bundle.sh $@

bun.lock: package.json
	bun install

.PHONY: all watch docker-watch build release bundle install-bundle

