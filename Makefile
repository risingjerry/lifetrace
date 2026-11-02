# Optional, untracked per-machine overrides (LABEL, SOURCES_LABEL, SIGN_IDENTITY, PREFIX, ...).
-include config.mk

PREFIX ?= $(HOME)/.local
LAUNCH_AGENTS ?= $(HOME)/Library/LaunchAgents
LOG ?= $(HOME)/Library/Logs/lifetrace.log
SOURCES_LOG ?= $(HOME)/Library/Logs/lifetrace-sources.log
# LaunchAgent label of the recorder; also its code-signing identifier (part of the Accessibility grant).
LABEL ?= dev.lifetrace.recorder
SOURCES_LABEL ?= dev.lifetrace.sources
BIN = $(PREFIX)/bin/lifetrace
# A stable signing identity keeps the designated requirement (and so the Accessibility grant) the same
# across rebuilds. Default: the first "Apple Development" identity in the keychain; none = ad-hoc
# signing (the grant must then be given again after every rebuild). Override: SIGN_IDENTITY="...".
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')

.PHONY: build test test-swift test-python install uninstall install-sources

build:
	swift build -c release
	codesign -f -i $(LABEL) -s "$(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)" .build/release/lifetrace
	@codesign -d -r- .build/release/lifetrace 2>&1 | grep designated

test: test-swift test-python

test-swift:
	swift test

test-python:
	python3 -m unittest discover -s Tests -t .

# Installs the binary, SCHEMA.md and the LaunchAgent plist. Does NOT load the agent:
# grant Accessibility first, then `launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENTS)/$(LABEL).plist`.
install: build
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/lifetrace" "$(LAUNCH_AGENTS)" "$$(dirname "$(LOG)")"
	install -m 755 .build/release/lifetrace "$(BIN)"
	install -m 644 SCHEMA.md "$(PREFIX)/share/lifetrace/SCHEMA.md"
	# plutil writes the values as plist strings (XML-escaped); no text substitution into XML.
	cp launchd/recorder.plist.in "$(LAUNCH_AGENTS)/$(LABEL).plist"
	plutil -replace Label -string "$(LABEL)" "$(LAUNCH_AGENTS)/$(LABEL).plist"
	plutil -remove ProgramArguments.0 "$(LAUNCH_AGENTS)/$(LABEL).plist"
	plutil -insert ProgramArguments.0 -string "$(BIN)" "$(LAUNCH_AGENTS)/$(LABEL).plist"
	plutil -replace StandardOutPath -string "$(LOG)" "$(LAUNCH_AGENTS)/$(LABEL).plist"
	plutil -replace StandardErrorPath -string "$(LOG)" "$(LAUNCH_AGENTS)/$(LABEL).plist"
	plutil -lint "$(LAUNCH_AGENTS)/$(LABEL).plist"
	@echo "installed $(BIN); LaunchAgent written to $(LAUNCH_AGENTS)/$(LABEL).plist (not loaded)"

# Python readers run from this checkout. Render only; never loads launchd.
install-sources:
	python3 -m lifetrace_sources.install --launch-agents "$(LAUNCH_AGENTS)" --log "$(SOURCES_LOG)" --label "$(SOURCES_LABEL)"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	-launchctl bootout gui/$$(id -u)/$(SOURCES_LABEL) 2>/dev/null
	rm -f "$(BIN)" "$(PREFIX)/share/lifetrace/SCHEMA.md" "$(LAUNCH_AGENTS)/$(LABEL).plist" "$(LAUNCH_AGENTS)/$(SOURCES_LABEL).plist"
