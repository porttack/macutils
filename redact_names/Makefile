# make: swift build -c release   make install: copy to $(PREFIX)/bin (sudo)   make clean
PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin

.PHONY: all install clean

all:
	swift build -c release

install: all
	sudo install -m 755 .build/release/redact_names $(BINDIR)/

clean:
	swift package clean
