# Build and install summarize-pdf.
#   make            build ./summarize-pdf
#   make install    build, then install to /usr/local/bin (asks for sudo)
#   make clean      remove the built binary
PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin

.PHONY: all install clean

all: summarize-pdf

summarize-pdf: summarize-pdf.swift
	swiftc summarize-pdf.swift -o summarize-pdf

install: summarize-pdf
	sudo install -m 755 summarize-pdf $(BINDIR)/

clean:
	rm -f summarize-pdf
