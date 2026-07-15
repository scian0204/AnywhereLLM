# 29. 앱 아이콘

## 목표

앱 아이콘이 없어 Finder/설정/About에서 기본 실행파일 아이콘으로 표시되던 것을
커스텀 아이콘으로 교체.

## 디자인

- **최종**: 플랫 & 심플 — 인디고(#5B5BD6) 단색 라운드 사각형 + 흰 "A" 모노그램(SF Rounded Heavy)
  + 우상단 4점 스파클 액센트. 그라데이션/글래스/그림자 등 효과 없음.
- **의미**: A = AnywhereLLM 이니셜, 스파클 = LLM(AI).
- 이터레이션 기록:
  1. 글래스+그라디언트(캐럿+스파클) 4종 → 사용자 반려 (이름/존재이유와 약한 연결)
  2. 컨셉 재정립(핀 음각/다크 비컨/패널 오버 윈도우/오빗) 4종 → 사용자 반려 (그라데이션 스타일 자체 반려)
  3. 플랫 4종 (핀+스파클 / 블랙+스파클 / 화이트+스파클 / A 모노그램) → **A 모노그램 채택**
- 채택 안 된 시안도 `scripts/gen-appicon.swift`의 variant 1~3으로 남아 있음.

## 구현

- `scripts/gen-appicon.swift` — 외부 의존성 0, AppKit/CoreGraphics로 드로잉.
  `swift scripts/gen-appicon.swift <variant 1-4> <out.png> [size]`. 최종 채택 = variant 4.
  모든 좌표는 1024 기준, 출력 크기에 맞춰 컨텍스트 스케일 → 16px까지 각 크기 네이티브 렌더링.
- `Resources/AppIcon.icns` — iconset(16~512@2x 10종) → `iconutil -c icns` 산출물. 저장소에 커밋.
- `Resources/Info.plist` — `CFBundleIconFile = AppIcon` 추가.
- `Makefile` bundle 타겟 — `cp Resources/AppIcon.icns $(CONTENTS)/Resources/` 추가.

재생성 절차 (디자인 변경 시):

```bash
mkdir -p /tmp/AppIcon.iconset
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_16x16.png 16
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_16x16@2x.png 32
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_32x32.png 32
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_32x32@2x.png 64
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_128x128.png 128
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_128x128@2x.png 256
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_256x256.png 256
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_256x256@2x.png 512
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_512x512.png 512
swift scripts/gen-appicon.swift 4 /tmp/AppIcon.iconset/icon_512x512@2x.png 1024
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

## 검증

- `make` 성공, `build/AnywhereLLM.app/Contents/Resources/AppIcon.icns` 존재,
  번들 Info.plist에 `CFBundleIconFile=AppIcon` 확인.
- 512px/32px 렌더 육안 확인 — A+스파클 실루엣 전 크기 판독 가능.

### 사용자 실측 필요

- Finder에서 build/AnywhereLLM.app 아이콘 표시 확인. 이전 빌드 아이콘이 보이면
  Finder 아이콘 캐시 문제 — 앱 번들을 다른 폴더로 옮겼다 되돌리거나 `killall Finder`.
