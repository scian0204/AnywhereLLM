# 31 — 보안·안정성 하드닝 감사

`audit/hardening` 브랜치. 전 소스(2,522줄)를 6개 차원(보안/동시성/파싱/에러/AX
견고성/개선점)으로 병렬 감사하고, 발견을 3-렌즈(적대적 반박·의도된 설계 여부·실사용
영향) 적대적 검증한 뒤 확정된 결함을 최소 수정으로 해결했다. 외부 의존성 0 유지,
하드 룰(보안 필드 차단·isEditable 거부목록 방향) 불변.

검증에서 명시적으로 확정된 8건 + 검증 에이전트 중단으로 미검증됐으나 코드 정독으로
진짜 결함이라 판정한 것들을 함께 수정. 각 항목 아래 근거.

## 해결 (심각도 높음)

### typeText frontmost 미검증 + 보안 필드 재확인 nil 우회 (TOCTOU) — TextTarget.swift
`typeText`가 대상 앱이 여전히 frontmost인지 확인하지 않아, 긴 스트림 도중 사용자가
다른 앱으로 전환하면 이후 flush가 엉뚱한 앱에 타이핑됐다. 또 보안 필드 재확인
`if let focused = focusedElement(), isSecureField(focused)`는 focusedElement()가 nil인
AX-침묵 앱(Chrome systemwide 항상 실패, 카카오톡류)에선 무력했다.
- 수정: `typeText(_:expectedBundleId:)`로 캡처 시점 bundleId를 받아, frontmost가
  다르면 즉시 중단. 매 flush마다 검사하므로 전환 직후 멈춘다. 호출부 3곳
  (`insert`, `ConversationController` flush, `PromptPanel.apply`)에 전달. AX 불필요 →
  거부목록 설계·AX-침묵 편집 대상 무회귀.

### UTF-16 서로게이트 쌍 분리로 이모지 손상 — TextTarget.swift
`typeText`가 `Array(text.utf16)`를 20단위 고정 stride로 잘라 각 조각을 한 CGEvent로
보냈다. 상위 서로게이트가 조각 끝(인덱스 19)에 걸리면 짝이 다음 이벤트로 밀려 두
이벤트 모두 깨진 UTF-16 → 이모지가 U+FFFD로 망가졌다(LLM 출력에 흔함).
- 수정: 경계가 상위 서로게이트(0xD800–0xDBFF)로 끝나면 한 칸 당겨 쌍을 한 이벤트에 유지.

### 핫키 등록 실패 무음 — 앱 유일 진입점 사망 — HotkeyManager.swift / AppDelegate.swift
`start()`가 `RegisterEventHotKey` 실패를 NSLog만 하고 void 반환. 핫키 변경은
stop()→start() 순서라 새 조합 등록이 실패하면(다른 앱 선점) 옛 핫키는 이미
해제됐고 앱은 진입점을 완전히 잃는다(재실행해도 같은 UserDefaults라 계속 사망).
- 수정: `start()`가 Bool 반환(InstallEventHandler OSStatus도 확인). AppDelegate는
  실패 시 NSAlert로 알리고 직전 성공 조합으로 복구·재등록해 앱을 계속 열 수 있게 함.

### Ollama/SSE 스트림 중간 에러 무음 폐기 — OllamaChatParser / SSEParser / LLMClient
200 헤더 후 서버가 스트림 중간에 실어 보내는 `{"error":…}`(러너 크래시·rate-limit·
upstream 실패)가 `.ignore`로 삼켜져 스트림이 성공으로 끝났다. immediate 모드는 잘린
출력을 선택 영역에 자동 교체, transcript 모드는 턴이 조용히 사라졌다.
- 수정: 두 파서에 `.error(String)` 케이스 추가·`obj["error"]` 감지, LLMClient가
  `LLMError.http(status:200)`로 throw해 에러 표시.

## 해결 (심각도 중간)

### 늦게 도착한 ⌘C가 사용자 클립보드 영구 손상 — TextTarget.swift
`clipboardCopyFallback`의 늦은-복원은 `requireWebEditorSelectionMetadata` 경로에만
있었다. 일반 프로브(타임아웃 0.15–0.3s)에서 대상 앱이 타임아웃 뒤 ⌘C를 처리하면
(Electron 등 메인 스레드 >150ms 정지) 사용자 원본(패스워드 등)이 프로브 결과로
영구 대체됐다.
- 수정: 모든 프로브 경로에 늦은-도착 스윕 일반화(반환 후 0.4s, changeCount 변하면
  backup 재복원). 메타데이터 전용 분기 흡수.

### bytes.lines가 JSON 문자열 내 U+2028/2029/0085에서 분리 — LLMClient.swift
`URLSession.AsyncBytes.lines`는 LS/PS/NEL도 줄바꿈으로 취급하는데 셋 다 JSON 문자열에
이스케이프 없이 올 수 있어(Python 계열 서버가 실제로 그렇게 보냄), 해당 문자가 든
delta 한 줄이 둘로 쪼개져 통째로 유실됐다.
- 수정: 프로토콜 프레이밍을 직접 `\n`으로. SSE·NDJSON 둘 다 \n에만 프레임하므로
  스펙-정확. 두 소비 루프를 파서 클로저 하나로 통합(중복 제거).

### [DONE]/done 없는 EOF를 성공으로 처리(절단) — LLMClient.swift
프록시 idle 타임아웃 등으로 연결이 조용히 끊기면 성공으로 종료돼 잘린 텍스트가
그대로 적용됐다.
- 수정: `sawDone` 추적, 센티널 없이 끝나면 `error.truncatedStream` throw.

### 확정 삽입의 취소 불가 지연 쓰기 — PromptPanel.swift
`apply`의 `asyncAfter(+0.15)`가 취소 불가라, 그 사이 핫키 재입력으로 새 패널이 뜨면
결과가 새 패널 입력창에 타이핑되고 컨텍스트도 오염됐다.
- 수정: `DispatchWorkItem`로 감싸 `present`/`dismiss`에서 취소 + 블록 내
  `!isVisible` 가드.

### AX 권한 런타임 취소 미반영 — AppDelegate.swift
`refreshAccessibility`가 false→true 전환에만 메뉴를 다시 그려, 실행 중 권한이
취소되면(TCC 리셋) 유일한 복구 항목 '접근성 권한 필요'가 다시 나타나지 않았다.
핫키를 눌러도 캡처·타이핑이 조용히 전부 실패.
- 수정: 어느 방향 전환이든 rebuildMenu. 추가로 togglePanel이 캡처 전 권한을
  재확인해 없으면 비프+설정 안내 후 중단.

### AXValue 무검증 force cast 크래시 — PanelPositioner.swift
`caretRect`·`axRect`의 `as! AXValue` 3곳이 형제 함수와 달리 `CFGetTypeID` 검사를
빠뜨려, AX 서버가 다른 CF 타입을 반환하는 앱에서 핫키마다 크래시할 수 있었다.
- 수정: 캐스트 전 `CFGetTypeID(value) == AXValueGetTypeID()` 가드 3곳 추가.

### 스트리밍 중 ⏎가 입력 텍스트 파괴 — ConversationView.swift / ConversationController.swift
`send()`가 `controller.send` 전에 `input=""`를 먼저 실행. 스트리밍 중엔 controller가
`guard !isStreaming`으로 조용히 거부해 사용자가 친 다음 지시가 흔적 없이 사라졌다.
- 수정: `send`가 `@discardableResult -> Bool`(수락 여부) 반환, 뷰는 true일 때만 입력 삭제.

## 해결 (심각도 낮음)

- **Keychain delete-then-add 무복구**(KeychainStore.swift): add 실패 시 방금 지운 키
  유실 → 이전 값 스냅샷 후 실패 시 재삽입, OSStatus 로그(키 자체는 미기록).
- **평문 HTTP로 API 키 전송 무경고**(SettingsView.swift): ATS가 IP 리터럴을 예외
  처리해 LAN http로 키가 평문 전송됨 → http+비loopback+키존재 시 주황 경고 캡션.
- **에러 응답 바디 무제한 읽기**(LLMClient.swift): 악성/고장 서버의 끝없는 청크에
  메모리 고갈 → 64KB 상한.
- **빈 Base URL/모델이 기본값 우회**(LLMClient.swift): 필드를 지우면 ""가 저장돼
  `?? 기본값` 미발동 → 공백/빈 값도 미설정으로 간주.
- **UInt32(Int) 트래핑 이니셜라이저**(HotkeyManager.swift): 범위 밖 UserDefaults 값에
  매 실행 크래시 → `UInt32(exactly:)` 폴백.
- **Carbon 핸들러 미해제 UAF**(HotkeyManager.swift): 현재 도달 불가지만 방어적으로
  `deinit`에서 RemoveEventHandler/UnregisterEventHotKey(포인터 nonisolated(unsafe)).
- **IPv6 origin 대괄호 유실**(Endpoint.swift): `[::1]`이 벗겨져 잘못된 origin →
  콜론 포함 호스트 재대괄호.
- **NSScreen.screens[0] 빈 배열 크래시**(PanelPositioner.swift): 화면 없을 때 →
  옵셔널 반환 + 폴백.
- **패널 dismiss 후 캡처 텍스트 메모리 잔존**(PromptPanel.swift): NSHostingView가 죽은
  세션(선택/전체 필드 내용 포함)을 무기한 보유 → dismiss·완료 시 contentView 비움.
- **죽은 코드**(ConversationController.swift): 미사용 `TranscriptEntry: Identifiable`+UUID 제거.
- **중복 0.15s 리터럴**(TextTarget.swift): `focusReturnDelay` 상수로 통합.

## 보류 (의도적)

- **setSelectedTextVerified false-positive**(TextTarget.swift:319): 자기-변경 필드에서
  AX 쓰기 미적용을 성공으로 오판할 수 있으나, 제안된 `after.contains(text)` 수정은
  텍스트 정규화 앱(스마트 따옴표·줄끝 변환)에서 이중 삽입이라는 더 흔한 회귀를
  유발한다. 현 동작(미적용 시 재-핫키로 복구 가능)이 더 방어적이라 보존.

## 테스트

`swift test` 35개 통과(신규 10). SSE/Ollama `.error` 케이스, 빈 선택 없음, usage-only
청크, IPv6 origin, ThinkTagFilter 부분 태그 flush·고아 close 태그.

## 수동 검증 필요 (GUI, 자동 불가)

- 긴 스트림 immediate 모드 중 다른 앱 전환 → 타이핑이 즉시 멈추는지.
- 이모지 든 응답이 온전히 삽입되는지(서로게이트).
- 실행 중 접근성 권한 취소 → 메뉴에 '권한 필요' 재등장 + 핫키 시 안내.
- 사용 중인 핫키 조합 녹화 → 알림 + 직전 조합 유지.
- 바쁜 앱(Electron)에서 선택 캡처 후 클립보드 원본 보존.
