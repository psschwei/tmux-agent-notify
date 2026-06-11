# tmux-agent-notify — build & install
#
# No Xcode required: `swift build` produces plain Mach-O binaries; `make app`
# hand-assembles a menu-bar .app bundle (LSUIElement) and ad-hoc codesigns it so
# TCC grants persist across rebuilds.

APP_NAME    := TmuxAgentNotify
BUNDLE_ID   := com.psschwei.tmux-agent-notify
VERSION     := 0.1.0
BUILD_DIR   := .build/release
APP_BUNDLE  := $(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
HOOK_DIR    := $(HOME)/.claude-tmux-notify
HOOK_SRC    := hooks/claude-tmux-notify.sh
AGENT_LABEL := com.psschwei.tmux-agent-notify
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT_LABEL).plist
APP_BINARY  := $(INSTALL_DIR)/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

.PHONY: all build ctl app install install-hooks install-agent uninstall-agent test clean

all: build

## build: compile both executables (debug)
build:
	swift build

## test: run the NotifyCore unit tests
test:
	swift test

## ctl: build the notifyctl CLI (release) and symlink it onto PATH-able location
ctl:
	swift build -c release --product notifyctl
	@echo "Built $(BUILD_DIR)/notifyctl"

## app: assemble the menu-bar .app bundle and ad-hoc codesign it
app:
	swift build -c release --product notifyd
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/notifyd $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	sed -e 's/@@NAME@@/$(APP_NAME)/g' \
	    -e 's/@@BUNDLE_ID@@/$(BUNDLE_ID)/g' \
	    -e 's/@@VERSION@@/$(VERSION)/g' \
	    packaging/Info.plist.in > $(APP_BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

## install: copy the .app into ~/Applications
install: app
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

## install-hooks: place the hook script and print the settings.json merge command
install-hooks:
	mkdir -p $(HOOK_DIR)
	cp $(HOOK_SRC) $(HOOK_DIR)/
	chmod +x $(HOOK_DIR)/$(notdir $(HOOK_SRC))
	@echo ""
	@echo "Hook installed at $(HOOK_DIR)/$(notdir $(HOOK_SRC))"
	@echo "Merge the hooks block into ~/.claude/settings.json, e.g.:"
	@echo ""
	@echo "  jq -s '.[0] * .[1]' ~/.claude/settings.json packaging/settings.snippet.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json"
	@echo ""

## install-agent: install + register a LaunchAgent so the app starts at login
install-agent: install
	mkdir -p $(HOME)/Library/LaunchAgents
	sed 's|@@APP_BINARY@@|$(APP_BINARY)|g' \
	    packaging/$(AGENT_LABEL).plist > $(AGENT_PLIST)
	@# bootout first in case an older copy is loaded; ignore errors if not loaded.
	-launchctl bootout gui/$(shell id -u)/$(AGENT_LABEL) 2>/dev/null
	launchctl bootstrap gui/$(shell id -u) $(AGENT_PLIST)
	@echo "LaunchAgent installed and started: $(AGENT_PLIST)"

## uninstall-agent: stop and remove the LaunchAgent
uninstall-agent:
	-launchctl bootout gui/$(shell id -u)/$(AGENT_LABEL) 2>/dev/null
	rm -f $(AGENT_PLIST)
	@echo "LaunchAgent removed"

## clean: remove build artifacts and the assembled bundle
clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
