# make: build ./socratic_summary   make install: copy to $(PREFIX)/bin (sudo)   make clean
PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin

.PHONY: all install clean

all: socratic_summary

socratic_summary: socratic_summary.swift
	swiftc -O -parse-as-library socratic_summary.swift -o socratic_summary

install: socratic_summary
	sudo install -m 755 socratic_summary $(BINDIR)/

clean:
	rm -f socratic_summary
