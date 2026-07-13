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

/// Drives one panel session. Two modes, decided by whether text was selected:
///
/// - **Insert mode** (no selection): the reply is typed straight into the target
///   text box as it streams (clipboard-free Unicode key events). No transcript,
///   no buttons. `applyMode` is ignored — insert is always live streaming.
/// - **Select mode** (selection present): full transcript UI with multi-turn and
///   a preview/immediate `applyMode` for confirming the replacement.
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
    /// Insert mode: close the panel once live streaming finishes.
    var onStreamingInsertDone: (() -> Void)?

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

    func send(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        errorMessage = nil
        pendingResult = nil

        if hasSelection {
            sendSelectTurn(trimmed)
        } else {
            sendInsertTurn(trimmed)
        }
    }

    // MARK: - Insert mode (live streaming into the target)

    private func sendInsertTurn(_ input: String) {
        let messages = buildMessages(latestUserInput: input, priorTurns: [])
        isStreaming = true

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
                for try await chunk in client.streamChat(messages: messages) {
                    if Task.isCancelled { break }
                    buffer += filter.feed(chunk)
                    // ponytail: 100ms batching keeps event volume sane on fast streams.
                    if ContinuousClock.now - lastFlush >= .milliseconds(100) {
                        flush()
                        lastFlush = .now
                    }
                }
                buffer += filter.flush()
                flush()
            } catch is CancellationError {
                flush() // keep whatever was already typed
            } catch {
                flush()
                errorMessage = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            isStreaming = false
            // Leave the panel up on error so the message is visible; else close.
            if errorMessage == nil { onStreamingInsertDone?() }
        }
    }

    // MARK: - Select mode (transcript + confirm)

    private func sendSelectTurn(_ input: String) {
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
            finishSelectStreaming(assistantIndex: assistantIndex)
        }
    }

    private func finishSelectStreaming(assistantIndex: Int) {
        isStreaming = false
        guard errorMessage == nil, assistantIndex < transcript.count else { return }
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
