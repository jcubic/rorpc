SOURCES := $(shell git ls-files SPEC.md template.html index.js Makefile)

all: dist/index.html

dist/index.html: $(SOURCES)
	mkdir -p ./dist
	node index.js > ./dist/index.html
