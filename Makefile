APP_NAME = MenuBarSleep
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
SRC = MenuBarSleep/main.swift
PLIST = MenuBarSleep/Info.plist

.PHONY: all clean install

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SRC) $(PLIST)
	@mkdir -p $(MACOS_DIR)
	swiftc -O -o $(MACOS_DIR)/$(APP_NAME) $(SRC) \
		-framework Cocoa
	@cp $(PLIST) $(CONTENTS)/Info.plist
	@xattr -cr $(APP_BUNDLE)
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

install: $(APP_BUNDLE)
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned."
