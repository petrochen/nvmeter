# NVMeter - build helpers. Everything is a plain Swift package; no Xcode project needed.
CONFIG ?= release
APP    := build/NVMeter.app

.PHONY: build app run dump icon shots release install-skill

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

# Notarized release: universal binary, Developer ID signature with hardened runtime, notarization, stapling.
# Needs the "Developer ID Application" identity in the Keychain and a notarytool profile:
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) --key <AuthKey.p8> --key-id <id> --issuer <issuer-uuid>
SIGN_ID        ?= Developer ID Application: ESCUDIX LTD (DCS482G699)
NOTARY_PROFILE ?= nvmeter-notary
VERSION        := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
RELDIR         := build/release
REL            := $(RELDIR)/NVMeter.app
ZIP            := $(RELDIR)/NVMeter-$(VERSION).zip

release:
	swift build -c release --arch arm64 --arch x86_64
	mkdir -p $(RELDIR) && find $(RELDIR) -mindepth 1 -delete
	mkdir -p $(REL)/Contents/MacOS $(REL)/Contents/Resources/Logos
	cp "$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/NVMeter" $(REL)/Contents/MacOS/NVMeter
	cp Resources/Info.plist $(REL)/Contents/Info.plist
	cp Resources/AppIcon.icns $(REL)/Contents/Resources/AppIcon.icns
	cp Resources/Logos/*.svg $(REL)/Contents/Resources/Logos/
	xattr -cr $(REL)
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(REL)
	codesign --verify --strict --verbose=2 $(REL)
	ditto -c -k --keepParent $(REL) $(RELDIR)/submit.zip
	xcrun notarytool submit $(RELDIR)/submit.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(REL)
	spctl --assess --type execute --verbose=2 $(REL)
	ditto -c -k --keepParent $(REL) $(ZIP)
	shasum -a 256 $(ZIP)
	@echo "Notarized $(ZIP)"
