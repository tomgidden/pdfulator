TAG=tomgidden/pdfulator

PDFS=$(patsubst %.md,%.pdf,$(wildcard *.md))

EXTRA_DOCKER_OPTS?=

ifdef THEME
EXTRA_DOCKER_OPTS+=-v $(THEME):/theme
endif

all: $(PDFS)

ifdef DEBUG
SWITCHES+= -d
DEBUGGING= \
	-v ./entrypoint.sh:/entrypoint.sh \
	-v ./work:/work \
	-v ./defaults:/defaults
endif

%.pdf: %.md
	($(if $(wildcard $*.yaml),\
		echo "---" && cat $*.yaml && echo "\n..." && cat $*.md,\
		$(if $(wildcard $*.yml),\
			echo "---" && cat $*.yml && echo "\n..." && cat $*.md,\
			cat $*.md \
		) \
	)) | docker run --rm --init -i $(EXTRA_DOCKER_OPTS) $(DEBUGGING) $(TAG) $(SWITCHES) - > $@

watch:
	docker run --rm --init -it $(EXTRA_DOCKER_OPTS) $(DEBUGGING) -v ./:/in $(TAG) $(SWITCHES) --watch

build:
	docker build -t $(TAG) .

release:
	docker buildx build --push --platform linux/arm64,linux/amd64 --tag $(TAG) .

