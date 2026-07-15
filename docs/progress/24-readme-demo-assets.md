# 24. 배포용 README 정비 + 데모 자산

## 목표

GitHub 공개를 위한 README 개편. 히어로 GIF·기능별 데모 GIF·설정 스크린샷을 포함해
프로젝트 첫인상에서 "무엇을 하는 앱인지"가 3초 안에 보이게 한다.

## 산출물

- `README.md` — 배지(플랫폼/Swift/의존성 0/OpenAI 호환), 히어로 GIF, 3-UX 데모,
  빠른 시작, 동작 원리 다이어그램, 보안 섹션.
- `docs/assets/`
  - `demo-replace.gif` — 교체 모드 (선택 → 패널 transcript → 자동 교체). 히어로.
  - `demo-insert.gif` — 삽입 모드 (패널 입력 → 대상 앱 실시간 타이핑).
  - `demo-viewonly.gif` — 보기 전용 (읽기 전용 메시지 버블 선택 → 결과 패널 유지).
  - `hero.png` — 교체 모드 스트리밍 중 스틸.
  - `settings.png` — 설정 창 (Base URL은 localhost로 임시 치환 후 촬영).
  - `demo-chat.html` — 데모 배경용 메신저 UI 정적 페이지. 재촬영 시 재사용.

## 데모 촬영 방법 (재현용)

1. `demo-chat.html`을 `python3 -m http.server 8517`로 서빙, Chrome에서 열기
   (`localhost` URL이 화면에 보이도록). 창 bounds `{310, 50, 1590, 930}`.
2. 바탕화면 노이즈(위젯·아이콘·워터마크) 가리기: TextEdit 빈 문서를 화면 전체 크기로
   Chrome 뒤에 깔아 배경 통일.
3. `screencapture -v -V <초> -D 1`로 녹화, 크롭 `crop=2560:1804:620:276`
   (크롬 탭·URL 바와 독 제외 — 챗 UI만), `fps=10, scale=800`,
   palettegen/paletteuse 2-pass로 GIF 변환 (개당 ~400KB).
4. 합성 입력 실측 주의점:
   - 패널은 **핫키 직후에만** 확실히 key — 중간에 다른 GUI 조작이 끼면 합성 키가
     Chrome으로 샌다. 녹화 시작 → 핫키 → 즉시 타이핑 순서 고정.
   - 한글은 AppleScript `keystroke` 불가 → `CGEventKeyboardSetUnicodeString` 헬퍼로 타이핑.
   - 패널에는 Edit 메뉴가 없어 ⌘V/⌘A 단축키가 안 먹힌다 (메뉴바 앱 특성).
   - Enter는 System Events `key code 36`이 확실 (CGEvent virtualKey 36은 유실 사례 있음).
   - Chrome 텍스트영역 선택은 트리플클릭(CGEvent clickState=3)으로.
5. 설정 스크린샷은 내부망 Base URL 노출 방지를 위해 AX로 필드 값을
   `http://localhost:11434/v1`로 바꿔 촬영 후 원복.

## 수동 테스트

- README의 이미지 6개 경로가 GitHub 렌더링에서 모두 표시되는지 push 후 확인 필요.
