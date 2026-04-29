APP_NAME = AIAggregator
APP_EXE = AIAggregatorApp
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources

all: $(APP_BUNDLE)

SWIFT_SOURCES = $(shell find Sources -name "*.swift")

$(APP_BUNDLE): Info.plist $(SWIFT_SOURCES)
	@mkdir -p $(APP_MACOS)
	@mkdir -p $(APP_RESOURCES)
	swift build -c release
	@cp .build/release/$(APP_EXE) $(APP_MACOS)/$(APP_NAME)
	@chmod +x $(APP_MACOS)/$(APP_NAME)
	@cp Info.plist $(APP_CONTENTS)/
	@echo "APPL????" > $(APP_CONTENTS)/PkgInfo
	@echo "Signing app..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: all
	@open $(APP_BUNDLE)

test:
	swift test

clean:
	@rm -rf $(BUILD_DIR)
	@rm -rf .build

release: all
	@cd $(BUILD_DIR) && zip -ry $(APP_NAME).zip $(APP_NAME).app
	@echo "Created $(BUILD_DIR)/$(APP_NAME).zip"

.PHONY: all clean test release run
