import AppKit
import LLMCore
import SwiftUI

/// One line in the on-screen transcript (select mode only).
struct TranscriptEntry: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// Drives one panel session. UX는 선택 유무 × applyMode로 갈린다:
///
/// - **Transcript UX** (선택 있음, 또는 applyMode=preview): 패널에 스트리밍 표시 +
///   multi-turn. preview면 확정 버튼(교체/삽입), immediate+선택이면 완료 시 자동 교체.
/// - **실시간 타이핑** (선택 없음 + applyMode=immediate): 패널을 숨기고 응답을
///   대상 텍스트박스에 그대로 타이핑 (클립보드 무접촉 유니코드 키 이벤트).
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

    let context: TargetContext
    /// True when there was a selection to replace (select mode), false for insert mode.
    var hasSelection: Bool { (context.selectedText?.isEmpty == false) }

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

    /// 패널에 transcript를 그리는 UX인지 (선택 모드 전부 + 삽입 모드 preview).
    /// 삽입 모드 immediate만 실시간 타이핑(패널 숨김) 경로를 탄다.
    var showsTranscriptUI: Bool { hasSelection || applyMode != "immediate" }

    func send(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        errorMessage = nil
        pendingResult = nil

        if showsTranscriptUI {
            sendTranscriptTurn(trimmed)
        } else {
            sendInsertTurn(trimmed)
        }
    }

    // MARK: - Insert mode (live streaming into the target)

    private func sendInsertTurn(_ input: String) {
        let messages = buildMessages(latestUserInput: input, priorTurns: [])
        isStreaming = true
        onStreamingInsertStart?()

        streamTask = Task { [weak self] in
            guard let self else { return }
            var filter = ThinkTagFilter()
            var buffer = ""
            var lastFlush = ContinuousClock.now

            func flush() {
                guard !buffer.isEmpty else { return }
                TextTargetService.typeText(buffer)
                buffer = ""
            }

            do {
                // 패널이 방금 key를 놓았다 — 대상 앱으로 키 포커스가 돌아올 시간을 준다
                // (선택 모드 apply와 같은 지연). 취소되면 CancellationError로 빠진다.
                try await Task.sleep(for: .milliseconds(150))
                for try await chunk in client.streamChat(messages: messages) {
                    try Task.checkCancellation()
                    buffer += filter.feed(chunk)
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
                flush()
            } catch is CancellationError {
                // 취소: 이미 타이핑된 건 그대로 두되, 남은 버퍼는 버린다.
                // (핫키 재입력으로 새 패널이 이미 key일 수 있어 추가 타이핑은 오입력 위험.)
            } catch {
                flush()
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
        transcript.append(TranscriptEntry(role: .user, text: input))
        let assistantIndex = transcript.count
        transcript.append(TranscriptEntry(role: .assistant, text: ""))

        let messages = buildMessages(latestUserInput: input, priorTurns: prior)
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
        // 취소된 세션(핫키 재입력/Esc)은 부분 결과를 절대 적용하지 않는다.
        guard !Task.isCancelled, errorMessage == nil, assistantIndex < transcript.count else { return }
        let result = transcript[assistantIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return }

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

    private func buildMessages(latestUserInput: String, priorTurns: [ChatMessage]) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemContent())]
        messages.append(contentsOf: priorTurns)
        let firstTurn = priorTurns.isEmpty
        messages.append(ChatMessage(role: "user", content: userContent(latestUserInput, firstTurn: firstTurn)))
        return messages
    }

    private func systemContent() -> String {
        var parts: [String] = []

        let global = (defaults.string(forKey: Self.systemPromptKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { parts.append(global) }

        if defaults.object(forKey: Self.includeAppNameKey) as? Bool ?? true,
           let app = context.appName, !app.isEmpty {
            parts.append("사용자는 \"\(app)\" 앱에서 텍스트를 작성 중입니다.")
        }

        if hasSelection {
            parts.append("사용자가 선택한 텍스트를 지시에 따라 편집하세요. 결과는 선택 영역을 대체할 텍스트만 출력하고, 설명이나 인사말은 넣지 마세요.")
        } else {
            parts.append("결과는 커서 위치에 삽입될 텍스트만 출력하고, 설명이나 인사말은 넣지 마세요.")
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
            parts.append("[선택한 텍스트]\n\(selection)")
        } else if defaults.object(forKey: Self.includeFullTextKey) as? Bool ?? false,
                  let full = context.fullText, !full.isEmpty {
            parts.append("[현재 필드 전체 내용]\n\(full)")
        }
        parts.append("[요청]\n\(input)")
        return parts.joined(separator: "\n\n")
    }
}
