# Build and install every tool in this repo.
#   make            build everything
#   make install    build, then install all tools to $(PREFIX)/bin (asks for sudo)
#   make clean      remove build products
# Build or install one tool with its own Makefile, e.g. `make -C redact_names install`.
# Note: the Import Scans to Notes AppleScript expects summarize-pdf in /usr/local/bin.
PREFIX ?= /usr/local
TOOLS   = notesimport redact_names socratic_summary

.PHONY: all install clean $(TOOLS)

all: $(TOOLS)

$(TOOLS):
	$(MAKE) -C $@

install:
	sudo mkdir -p $(PREFIX)/bin
	@for t in $(TOOLS); do $(MAKE) -C $$t install PREFIX=$(PREFIX) || exit 1; done

clean:
	@for t in $(TOOLS); do $(MAKE) -C $$t clean; done
