APP_NAME    = AnywhereLLM
BUNDLE_ID   = kr.scian0204.AnywhereLLM
BUILD_DIR   = build
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents
BIN         = .build/release/$(APP_NAME)

.PHONY: all app run clean

all: app

$(BIN):
	swift build -c release

app: $(BIN)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	codesign --force --sign - --options runtime --identifier $(BUNDLE_ID) $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
