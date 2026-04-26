APP_NAME = AIAggregator
BUNDLE_ID = com.graywzc.AIAggregator
SRC_DIR = Sources
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources

SWIFTC = swiftc
ARCH := $(shell uname -m)
ifeq ($(ARCH),arm64)
SWIFT_TARGET = arm64-apple-macosx13.0
else
SWIFT_TARGET = x86_64-apple-macosx13.0
endif
SWIFT_FLAGS = -parse-as-library -target $(SWIFT_TARGET)

SRCS = $(wildcard $(SRC_DIR)/*.swift)

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SRCS) Info.plist
	@mkdir -p $(APP_MACOS)
	@mkdir -p $(APP_RESOURCES)
	$(SWIFTC) $(SWIFT_FLAGS) $(SRCS) -o $(APP_MACOS)/$(APP_NAME)
	@cp Info.plist $(APP_CONTENTS)/
	@echo "Built $(APP_BUNDLE)"

run: all
	@open $(APP_BUNDLE)

clean:
	@rm -rf $(BUILD_DIR)

.PHONY: all run clean
