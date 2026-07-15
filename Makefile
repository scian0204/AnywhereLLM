APP_NAME    = AnywhereLLM
VERSION     = 0.1.0
BUNDLE_ID   = kr.scian0204.AnywhereLLM
BUILD_DIR   = build
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents
BIN         = .build/release/$(APP_NAME)
# 배포용 유니버설 빌드 산출물 경로 (swift build --arch arm64 --arch x86_64)
UNIVERSAL_BIN = .build/apple/Products/Release/$(APP_NAME)
ZIP         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip
# "AnywhereLLM Dev" 자가서명 인증서 있으면 사용 (TCC 권한이 재빌드에도 유지됨),
# 없으면 ad-hoc(-). 인증서 생성: scripts/make-signing-cert.sh
CODESIGN_ID := $(shell security find-identity -p codesigning -v 2>/dev/null | grep -q "AnywhereLLM Dev" && echo "AnywhereLLM Dev" || echo "-")

.PHONY: all app run clean build dist bundle

all: app

build:
	swift build -c release

app: build
	$(MAKE) bundle

# 배포용: 유니버설 바이너리(arm64 + x86_64) 앱 번들 zip + sha256
dist:
	swift build -c release --arch arm64 --arch x86_64
	$(MAKE) bundle BIN=$(UNIVERSAL_BIN)
	ditto -c -k --keepParent $(APP_BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP)

bundle:
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/$(APP_NAME)
	cp -R $(dir $(BIN))$(APP_NAME)_$(APP_NAME).bundle $(CONTENTS)/Resources/
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(date +%y%m%d.%H%M%S)" $(CONTENTS)/Info.plist
	codesign --force --sign "$(CODESIGN_ID)" --options runtime --identifier $(BUNDLE_ID) $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) $(VERSION) (sign: $(CODESIGN_ID))"

run: app
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
