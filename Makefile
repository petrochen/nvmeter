# NVMeter - build helpers. Everything is a plain Swift package; no Xcode project needed.
CONFIG ?= release
APP    := build/NVMeter.app

.PHONY: build app run dump

build:
	swift build -c $(CONFIG)

# Assembles build/NVMeter.app (files are overwritten in place; `rm -r build` to start clean).
app: build
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/NVMeter" $(APP)/Contents/MacOS/NVMeter
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	xattr -cr $(APP)
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

dump: app
	$(APP)/Contents/MacOS/NVMeter --dump
