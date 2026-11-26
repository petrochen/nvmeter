# NVMeter - build helpers. Everything is a plain Swift package; no Xcode project needed.
CONFIG ?= release
APP    := build/NVMeter.app

.PHONY: build app run dump icon shots

build:
	swift build -c $(CONFIG)

# Assembles build/NVMeter.app (files are overwritten in place; `rm -r build` to start clean).
app: build
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/NVMeter" $(APP)/Contents/MacOS/NVMeter
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	mkdir -p $(APP)/Contents/Resources/Logos
	cp Resources/Logos/*.svg $(APP)/Contents/Resources/Logos/
	xattr -cr $(APP)
	codesign --force --sign - $(APP)
	touch $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

dump: app
	$(APP)/Contents/MacOS/NVMeter --dump

# Regenerates Resources/AppIcon.icns and docs/icon.png (the .icns is committed, so building does not need this).
icon:
	swift scripts/make-icon.swift

# Light and dark screenshots with a simulated hover crosshair into build/shots (takes ~2 minutes).
shots: app
	$(APP)/Contents/MacOS/NVMeter --screenshot build/shots --appearance light
	$(APP)/Contents/MacOS/NVMeter --screenshot build/shots --appearance dark

# Installs the agent skill for Claude Code and Codex (copies; re-run after editing skills/nvmeter).
install-skill:
	for d in $(HOME)/.claude/skills $(HOME)/.codex/skills; do \
		mkdir -p $$d && rm -rf $$d/nvmeter && cp -R skills/nvmeter $$d/nvmeter; done
	@echo "Installed skills/nvmeter into ~/.claude/skills and ~/.codex/skills"
