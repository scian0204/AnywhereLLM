# 25. 버전관리 시작 + Homebrew 배포

## 목표

앱 버전을 단일 소스로 관리하고, GitHub Release + Homebrew tap으로 설치 경로를 연다.

## 결정

- **버전 단일 소스 = Makefile `VERSION`**. 번들 조립 시 PlistBuddy로
  `CFBundleShortVersionString`을 덮어쓴다 (Resources/Info.plist의 정적값은 폴백).
  `CFBundleVersion`은 기존대로 빌드 타임스탬프.
- **배포 산출물 = 유니버설 바이너리** (`swift build --arch arm64 --arch x86_64`).
  Intel Mac도 macOS 14를 지원하므로. 산출물 경로가 네이티브 빌드와 다름
  (`.build/apple/Products/Release/`) — Makefile `UNIVERSAL_BIN` 참조.
- **Homebrew는 cask + 개인 tap** (`scian0204/homebrew-tap`, `Casks/anywherellm.rb`).
  소스 빌드 formula가 아닌 cask인 이유: 사용자에게 Swift 6 툴체인을 요구하지 않기 위해.
- **공증 없음 → `--no-quarantine` 필수**. 자가서명("AnywhereLLM Dev") 앱은 격리 속성이
  붙으면 Gatekeeper가 "손상됨"으로 차단. cask caveats와 README에 명시.
  Apple Developer Program 가입 시 공증으로 대체 가능(그때 이 플래그 제거).

## 산출물

- `Makefile` — `VERSION` 변수, `dist` 타겟(유니버설 빌드 + zip + sha256),
  조립 공통부를 `bundle` 타겟으로 분리 (`app`과 `dist`가 공유).
- `README.md` — 설치 섹션을 Homebrew(권장) / 소스 빌드로 이원화.
- git tag `v0.1.0` + GitHub Release (자산: `AnywhereLLM-0.1.0.zip`).
- 별도 저장소 `scian0204/homebrew-tap` — cask 정의.

## 릴리스 절차 (다음 버전부터)

1. Makefile `VERSION` 올리고 커밋.
2. `make dist` — zip + sha256 출력.
3. `git tag vX.Y.Z && git push --tags`
4. `gh release create vX.Y.Z build/AnywhereLLM-X.Y.Z.zip`
5. homebrew-tap의 `Casks/anywherellm.rb`에서 `version`·`sha256` 갱신 후 push.

## 수동 테스트

- [ ] `brew install --cask --no-quarantine scian0204/tap/anywherellm` 후 앱 실행,
  접근성 권한 부여, 핫키 동작 확인 (다른 머신이면 이상적).
- [x] `make dist` 산출물 `lipo -archs` = `x86_64 arm64`.
- [x] `make app` 회귀 없음 (bundle 분리 후에도 동일 동작).
