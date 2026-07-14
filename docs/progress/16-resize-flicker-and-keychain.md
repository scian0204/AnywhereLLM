# 16 — resize-flicker-and-keychain

15의 layout()+fittingSize 리사이즈 도입 후 사용자 보고 2건:
1. 높이가 틱 단위로 미세하게 바뀌며 깜빡임.
2. 쓸 때마다 맥 비밀번호 요구.

## 1. 리사이즈 진동 (깜빡임)

원인: `resizeToFit`의 `target != frame.size` **정확 비교**. `fittingSize`는
소수점 크기(예: 327.66)를 주는데 `setFrame` 후 AppKit이 정수 픽셀로 반올림
(328) → 다음 layout()에서 다시 소수점 목표와 달라짐 → setFrame → layout() →
… 무한 리사이즈 루프 = 깜빡임.

수정: 목표 크기를 `ceil`로 정수화 + 0.5px 허용오차 가드.

## 2. 키체인 암호 프롬프트

원인 조합:
- 키체인 항목(service `kr.scian0204.AnywhereLLM`, account `apiKey`)이
  예전 서명(ad-hoc 시절) 바이너리 소유로 생성됨 — 레거시 키체인 ACL은
  소유 앱 서명 불일치 시 읽기마다 암호를 요구.
- `LLMClient.streamChat`이 요청마다 `KeychainStore.get()` 호출 → 매 전송마다 프롬프트.
- 기존 `set()`은 `SecItemUpdate` — **기존 항목의 ACL을 그대로 보존**하므로
  설정에서 키를 다시 저장해도 안 고쳐졌다.

수정 (`KeychainStore.set`):
- 빈 값 → `delete()` — 로컬 서버(Ollama)는 키가 없으니 항목 자체를 없애
  프롬프트를 원천 차단.
- 비어있지 않으면 삭제 후 `SecItemAdd` — 현재 바이너리 소유의 새 ACL.

**사용자 조치 필요 (1회)**: 설정 열고 API 키 필드를 비우기(또는 키 사용자는
다시 입력). 이때 마지막 프롬프트가 한 번 뜰 수 있음 — 이후 재발 없음.

## 검증

- `swift build` 경고 0, `make` 성공. LLMCore 무변경.
- GUI/키체인 동작은 실측 필요: (1) 미리보기 스트리밍 중 패널이 부드럽게
  자라는지(깜빡임 무), (2) API 키 비운 뒤 전송 시 암호 프롬프트 없는지.
