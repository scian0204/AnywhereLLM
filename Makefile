APP_NAME    = AnywhereLLM
BUNDLE_ID   = kr.scian0204.AnywhereLLM
BUILD_DIR   = build
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents
BIN         = .build/release/$(APP_NAME)
# "AnywhereLLM Dev" 자가서명 인증서 있으면 사용 (TCC 권한이 재빌드에도 유지됨),
# 없으면 ad-hoc(-). 인증서 생성: scripts/make-signing-cert.sh
CODESIGN_ID := $(shell security find-identity -p codesigning -v 2>/dev/null | grep -q "AnywhereLLM Dev" && echo "AnywhereLLM Dev" || echo "-")

.PHONY: all app run clean build

all: app

build:
	swift build -c release

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(date +%y%m%d.%H%M%S)" $(CONTENTS)/Info.plist
	codesign --force --sign "$(CODESIGN_ID)" --options runtime --identifier $(BUNDLE_ID) $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) (sign: $(CODESIGN_ID))"

run: app
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
