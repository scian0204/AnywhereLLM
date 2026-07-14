# 19 — selection-anchor-position

사용자 요구: 위치 모드가 캐럿 추적일 때, 포커스 없는 텍스트 선택(보기 전용)이면
선택된 텍스트 위치 쪽에 패널이 떠야 함.

## 원인

`PanelPositioner`가 자체 `focusedElement()` 사본을 갖고 있었는데 **systemwide
질의 전용** — TextTarget에서 18에 고친 것과 동일한 Chrome 불능 버그. Chrome에선
요소를 못 얻어 항상 마우스 폴백으로 떨어졌다. 캐럿 로직 자체는
`kAXSelectedTextRange` + `BoundsForRange`로 선택 전체 bounds를 이미 앵커로 쓰므로,
요소만 제대로 얻으면 선택 텍스트 위치 추적이 된다.

## 변경

- `origin(for:)` → `origin(for:anchor:)`: **captureContext가 캡처한 요소를 그대로
  전달받아** 앵커로 사용. 재질의 삭제 (캡처와 위치가 다른 요소를 볼 수 없게 되고,
  Chrome systemwide 불능도 자동 해소 — 캡처는 18의 앱 요소 폴백/웨이크 경유).
  호출처는 AppDelegate.togglePanel 1곳.
- AXFrame 폴백에 높이 상한(≤300pt): 보기 전용 컨테이너(AXWebArea 등)의 frame은
  뷰포트 전체라 앵커로 부적합 — 그 경우 마우스 폴백(선택 끝 지점 근처)이 낫다.
  ponytail: 300pt 임계는 필드/컨테이너 구분 휴리스틱, 오판 사례 나오면 조정.

## 재수정 (1차 "안됨" 보고 후 — 라이브 Chrome 실측)

1차 수정은 요소 전달만 고쳤고 bounds API를 그대로 믿었다. 실측 결과:

- **Chromium 웹 영역의 classic `BoundsForRange`는 실선택(34자)에도 err 0 +
  제로 크기 rect `(0, 1112, 0, 0)`을 반환** — 성공 코드+쓰레기, 교체 무시
  (progress/18)와 같은 패턴. 기존 가드(isFinite/isNull)를 통과해 앵커가 화면
  왼쪽 끝으로 날아갔다. 이게 "안됨"의 원인.
- **텍스트마커 API는 정상**: `AXSelectedTextMarkerRange` +
  `AXBoundsForTextMarkerRange` → `(30, 537, 1184, 39)` (실제 선택 라인 bounds,
  VoiceOver가 쓰는 경로).

변경: `validAnchorRect` — 제로 크기 rect 거부 (순수 캐럿은 width 0이어도
height > 0). 앵커 체인 = classic BoundsForRange → **텍스트마커 폴백** →
AXFrame(≤300pt) → 마우스.

## 검증

- 라이브 Chrome 실측: classic 제로 rect 재현 + 텍스트마커 정상 bounds 확인
  (백그라운드 PID 질의 — 통제 재현, 사용자 포커스 무접촉).
- `swift build` 경고 0, `make` 성공. LLMCore 무변경.
- GUI 실측 필요 (위치 모드 = 캐럿 추적):
  1. 웹페이지 본문 텍스트 선택 → 핫키 → 패널이 선택 텍스트 근처에 뜨는지.
  2. 회귀: 편집 필드 캐럿 추적 기존대로 (캐럿 아래).
  3. 마우스/중앙 모드 무영향.
