SOURCES := $(shell git ls-files SPEC.md template.html index.js Makefile)

all: build

index.html: SPEC.md template.html index.js Makefile
	node index.js

.last_build: $(SOURCES)
	node index.js
	@touch $@

build: .last_build

.last_deploy: .last_build
	scp index.html mydevil:~/rorpc.org/ < /dev/null
	@touch $@

deploy: .last_deploy
