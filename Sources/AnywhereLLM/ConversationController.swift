import AppKit
import LLMCore
import SwiftUI

/// One line in the on-screen transcript (select mode only).
struct TranscriptEntry {
    enum Role { case user, assistant }
    let role: Role
    var text: String
}

/// Drives one panel session. UX는 편집 가능성 × 선택 유무 × applyMode로 갈린다:
///
/// - **보기 전용** (대상이 편집 불가 — 웹페이지 본문/PDF 등): 패널에 결과를 표시하고
///   그대로 남긴다. 적용/자동 닫기 없음 — 삽입할 곳이 없다.
/// - **Transcript UX** (편집 가능 + (선택 있음 또는 applyMode=preview)): 패널에 스트리밍
///   표시 + multi-turn. preview면 확정 버튼(교체/삽입), immediate+선택이면 완료 시 자동 교체.
/// - **실시간 타이핑** (편집 가능 + 선택 없음 + applyMode=immediate): 패널을 숨기고
///   응답을 대상 텍스트박스에 그대로 타이핑 (클립보드 무접촉 유니코드 키 이벤트).
///
/// 선택이 있으면 첫 턴은 빈 입력으로도 전송 가능 — 프롬프트 프로필이 지시 역할.
///
/// Settings (UserDefaults, defaults hardcoded — settings UI is step 6):
///   applyMode       "preview"(default) / "immediate"   [select mode only]
///   includeAppName  Bool (default true)
///   includeFullText Bool (default false)
///   systemPrompt    String (default "")
@MainActor
final class ConversationController: ObservableObject {
    static let applyModeKey = "applyMode"
    static let includeAppNameKey = "includeAppName"
    static let includeFullTextKey = "includeFullText"
    static let systemPromptKey = "systemPrompt"

    @Published var transcript: [TranscriptEntry] = []
    @Published var isStreaming = false
    @Published var errorMessage: String?
    /// Select mode: the completed reply awaiting insert confirmation (preview).
    @Published var pendingResult: String?

    /// Transcript UX의 결과 표시용 — 마지막 assistant 응답만 노출.
    /// 대화 버블 대신 결과 단건 표기 (multi-turn 히스토리는 내부적으로 유지).
    var latestAssistantText: String? {
        transcript.last(where: { $0.role == .assistant })?.text
    }

    let context: TargetContext
    /// True when there was a selection to replace (select mode), false for insert mode.
    var hasSelection: Bool { (context.selectedText?.isEmpty == false) }
    /// True when this session is an image (screen-capture) query — always view-only.
    var hasImage: Bool { context.image != nil }
    /// Captured PNG bytes for the panel thumbnail; nil for text sessions.
    var capturedImageData: Data? { context.image }
    /// Base64 of the captured image; attached to the first user message only.
    private var imageBase64: String? { context.image?.base64EncodedString() }

    private let client: LLMClient
    private let defaults: UserDefaults
    private var streamTask: Task<Void, Never>?
    /// Select mode: close the panel then run insert after a focus-return delay.
    var onApply: ((String) -> Void)?
    /// Insert mode: hide the panel BEFORE typing starts. 합성 키 이벤트는 key window로
    /// 라우팅되므로, 패널이 key를 쥔 채로는 타이핑이 대상 앱에 도달하지 않는다.
    var onStreamingInsertStart: (() -> Void)?
    /// Insert mode: close the panel once live streaming finishes.
    var onStreamingInsertDone: (() -> Void)?
    /// Insert mode: streaming failed — re-show the (hidden) panel so the error is visible.
    var onStreamingInsertError: (() -> Void)?

    init(context: TargetContext,
         client: LLMClient = LLMClient(),
         defaults: UserDefaults = .standard) {
        self.context = context
        self.client = client
        self.defaults = defaults
    }

    /// Select mode preview text (collapsed at the top of the panel).
    var selectionPreview: String? {
        guard let s = context.selectedText, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Sending

    /// 대상이 편집 불가면 결과를 넣을 곳이 없다 — 항상 보기 전용(패널 유지).
    var isViewOnly: Bool { !context.isEditable }

    /// 패널에 transcript를 그리는 UX인지 (보기 전용 + 선택 모드 전부 + 삽입 모드 preview).
    /// 편집 가능 + 선택 없음 + immediate만 실시간 타이핑(패널 숨김) 경로를 탄다.
    var showsTranscriptUI: Bool { isViewOnly || hasSelection || applyMode != "immediate" }

    /// 반환값 = 턴이 수락됐는지. false면 뷰가 입력을 지우지 않아야 한다(스트리밍 중
    /// 또는 빈 요청 등으로 거부된 입력이 조용히 사라지는 데이터 유실 방지).
    @discardableResult
    func send(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming else { return false }
        // 선택이 있으면 첫 턴은 빈 입력 허용 — 프롬프트 프로필이 지시 역할.
        // 프로필까지 비어 있으면 지시가 전무한 요청(오입력 ⏎일 확률) — immediate 모드에선
        // 무지시 응답이 선택을 자동 교체해버리므로 막는다.
        let profile = (defaults.string(forKey: Self.systemPromptKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 첫 턴은 빈 입력 허용 — 이미지는 항상 보기 전용이라 무지시 전송이 무해하므로
        // 프로필이 없어도 허용. 선택은 immediate 모드 자동 교체 위험 때문에 프로필이
        // 비어 있으면 막는다(무지시 응답이 선택을 덮어쓰는 것 방지).
        guard !trimmed.isEmpty
            || (transcript.isEmpty && (hasImage || (hasSelection && !profile.isEmpty)))
        else { return false }
        errorMessage = nil
        pendingResult = nil

        if showsTranscriptUI {
            sendTranscriptTurn(trimmed)
        } else {
            sendInsertTurn(trimmed)
        }
        return true
    }

    // MARK: - Insert mode (live streaming into the target)

    private func sendInsertTurn(_ input: String) {
        let messages = [ChatMessage(role: "system", content: systemContent()),
                        ChatMessage(role: "user", content: userContent(input, firstTurn: true))]
        isStreaming = true

        // context는 MainActor 격리(AXUIElement 포함, non-Sendable) — Task 클로저에서
        // 참조 불가하므로 Sendable한 bundleId만 미리 지역으로 뽑아 넘긴다.
        let targetBundleId = context.bundleId
        streamTask = Task { [weak self] in
            guard let self else { return }
            var filter = ThinkTagFilter()
            var buffer = ""
            var lastFlush = ContinuousClock.now
            var typingStarted = false

            // 첫 가시 콘텐츠가 나올 때까지 패널을 띄워 로딩을 보여주고, 타이핑 직전에야
            // 숨긴다. 숨긴 뒤 대상 앱으로 key 포커스가 돌아올 시간을 준다
            // (선택 모드 apply와 같은 지연). 취소되면 CancellationError로 빠진다.
            @MainActor func beginTypingIfNeeded() async throws {
                guard !typingStarted else { return }
                typingStarted = true
                onStreamingInsertStart?()
                try await Task.sleep(for: .seconds(TextTargetService.focusReturnDelay))
            }

            func flush() {
                guard !buffer.isEmpty else { return }
                // 캡처 시점 대상 앱이 여전히 frontmost일 때만 타이핑 — 사용자가 스트림
                // 도중 다른 앱으로 전환하면 이후 flush는 아무 것도 하지 않는다.
                TextTargetService.typeText(buffer, expectedBundleId: targetBundleId)
                buffer = ""
            }

            do {
                for try await chunk in client.streamChat(messages: messages) {
                    try Task.checkCancellation()
                    buffer += filter.feed(chunk)
                    guard !buffer.isEmpty else { continue }
                    try await beginTypingIfNeeded()
                    // ponytail: 100ms batching keeps event volume sane on fast streams.
                    if ContinuousClock.now - lastFlush >= .milliseconds(100) {
                        flush()
                        lastFlush = .now
                    }
                }
                // 취소되면 AsyncThrowingStream은 throw 없이 nil-종료로 루프를 빠져나온다 —
                // 여기서 한 번 더 확인해야 잔여 버퍼가 catch로 넘어가 드롭된다.
                try Task.checkCancellation()
                buffer += filter.flush()
                if !buffer.isEmpty { try await beginTypingIfNeeded() }
                flush()
            } catch is CancellationError {
                // 취소: 이미 타이핑된 건 그대로 두되, 남은 버퍼는 버린다.
                // (핫키 재입력으로 새 패널이 이미 key일 수 있어 추가 타이핑은 오입력 위험.)
            } catch {
                // 타이핑 전 에러면 패널이 아직 key — 여기서 flush하면 패널이 이벤트를 먹는다.
                if typingStarted { flush() }
                errorMessage = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            isStreaming = false
            // Success: close. Error: re-show the hidden panel so the message is visible.
            if errorMessage == nil {
                onStreamingInsertDone?()
            } else {
                onStreamingInsertError?()
            }
        }
    }

    // MARK: - Transcript mode (선택 모드 전부 + 삽입 모드 preview: 화면 표시 + 확정)

    private func sendTranscriptTurn(_ input: String) {
        // Prior completed turns are everything currently in the transcript.
        let prior = transcript.map {
            ChatMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        // 접은 본문([선택한 텍스트] 포함)을 transcript에 저장 — 이후 턴의 prior에서도
        // 선택 컨텍스트가 유지된다 (화면엔 assistant 결과만 그려 표시 무영향).
        let composed = userContent(input, firstTurn: prior.isEmpty)
        transcript.append(TranscriptEntry(role: .user, text: composed))
        let assistantIndex = transcript.count
        transcript.append(TranscriptEntry(role: .assistant, text: ""))

        var messages = [ChatMessage(role: "system", content: systemContent())]
            + prior
            + [ChatMessage(role: "user", content: composed)]
        // 이미지 질의: 캡처 이미지를 첫 user 메시지에만 붙인다. 매 턴 첫 user 턴에
        // 재부착해 multi-turn에서도 이미지 컨텍스트가 유지된다 (prior는 텍스트만 복원).
        if let b64 = imageBase64, let i = messages.firstIndex(where: { $0.role == "user" }) {
            messages[i].imageBase64 = b64
        }
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            var filter = ThinkTagFilter()
            do {
                for try await chunk in client.streamChat(messages: messages) {
                    if Task.isCancelled { break }
                    let visible = filter.feed(chunk)
                    if !visible.isEmpty, assistantIndex < transcript.count {
                        transcript[assistantIndex].text += visible
                    }
                }
                let tail = filter.flush()
                if !tail.isEmpty, assistantIndex < transcript.count {
                    transcript[assistantIndex].text += tail
                }
            } catch is CancellationError {
                // leave partial text
            } catch {
                errorMessage = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            finishTranscriptStreaming(assistantIndex: assistantIndex)
        }
    }

    private func finishTranscriptStreaming(assistantIndex: Int) {
        isStreaming = false
        let result = assistantIndex < transcript.count
            ? transcript[assistantIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        // 토큰 0개로 끝난 턴(에러/무응답)은 user+assistant 쌍을 제거 — 빈 assistant가
        // 다음 턴 prior로 전송되는 것과, 첫 턴 실패 후 빈 ⏎ 재시도가 첫 턴 가드에
        // 막히는 것을 함께 방지한다.
        if result.isEmpty, assistantIndex < transcript.count {
            transcript.removeSubrange((assistantIndex - 1)...assistantIndex)
        }
        // 취소된 세션(핫키 재입력/Esc)은 부분 결과를 절대 적용하지 않는다.
        guard !Task.isCancelled, errorMessage == nil, !result.isEmpty else { return }

        // 보기 전용: 적용할 곳이 없다 — 결과를 패널에 그대로 남긴다 (모드 무관).
        guard !isViewOnly else { return }

        if applyMode == "immediate" {
            onApply?(result)
        } else {
            pendingResult = result
        }
    }

    /// Confirm the pending replacement (preview mode, or ⌘⏎).
    func applyPending() {
        guard let result = pendingResult else { return }
        onApply?(result)
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Prompt construction

    private var applyMode: String { defaults.string(forKey: Self.applyModeKey) ?? "preview" }

    private func systemContent() -> String {
        var parts: [String] = []

        let global = (defaults.string(forKey: Self.systemPromptKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { parts.append(global) }

        if defaults.object(forKey: Self.includeAppNameKey) as? Bool ?? true,
           let app = context.appName, !app.isEmpty {
            parts.append(L("prompt.appContext", app))
        }

        if isViewOnly {
            // 결과가 어디에도 삽입되지 않고 패널에 표시된다 — 답변 형식 제약 없음.
            parts.append(L("prompt.viewOnly"))
        } else if hasSelection {
            parts.append(L("prompt.editSelection"))
        } else {
            parts.append(L("prompt.insertAtCursor"))
        }

        // think 끄기 소프트 스위치 (Qwen3 계열): chat_template_kwargs를 못 쓰는
        // 서버(Ollama /v1 등)를 위한 보조 수단. 미지원 모델엔 무해한 텍스트.
        if defaults.bool(forKey: LLMClient.disableThinkKey) {
            parts.append("/no_think")
        }

        return parts.joined(separator: "\n\n")
    }

    private func userContent(_ input: String, firstTurn: Bool) -> String {
        // Only fold the selection / full text into the FIRST user turn.
        guard firstTurn else { return input }

        var parts: [String] = []
        if let selection = selectionPreview {
            parts.append(L("prompt.sectionSelection") + "\n\(selection)")
        } else if defaults.object(forKey: Self.includeFullTextKey) as? Bool ?? false,
                  let full = context.fullText, !full.isEmpty {
            parts.append(L("prompt.sectionFullText") + "\n\(full)")
        }
        // 빈 입력(선택 + ⏎만) — 프롬프트 프로필이 지시 역할이므로 [요청] 생략.
        if !input.isEmpty { parts.append(L("prompt.sectionRequest") + "\n\(input)") }
        return parts.joined(separator: "\n\n")
    }
}
