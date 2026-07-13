import AppKit
import SwiftUI

/// One line in the on-screen transcript.
struct TranscriptEntry: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// Drives one panel session: holds the captured target, the transcript, and the
/// streaming LLM task. Built fresh each time the panel opens and reset when it closes.
///
/// Settings (UserDefaults, defaults hardcoded — settings UI is step 6):
///   applyMode       "preview"(default) / "immediate"
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
    /// The last completed assistant reply, awaiting insert confirmation (preview mode).
    @Published var pendingResult: String?

    let context: TargetContext
    /// True when there was a selection to replace, false for caret insertion.
    var hasSelection: Bool { (context.selectedText?.isEmpty == false) }

    private let client: LLMClient
    private let defaults: UserDefaults
    private var streamTask: Task<Void, Never>?
    /// Closes the panel then runs insert after a focus-return delay. Injected by the panel.
    var onApply: ((String) -> Void)?

    init(context: TargetContext,
         client: LLMClient = LLMClient(),
         defaults: UserDefaults = .standard) {
        self.context = context
        self.client = client
        self.defaults = defaults
    }

    /// The preview text shown collapsed at the top, if any selection was captured.
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
        transcript.append(TranscriptEntry(role: .user, text: trimmed))
        let assistantIndex = transcript.count
        transcript.append(TranscriptEntry(role: .assistant, text: ""))

        let messages = buildMessages(latestUserInput: trimmed)
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in client.streamChat(messages: messages) {
                    if Task.isCancelled { break }
                    if assistantIndex < transcript.count {
                        transcript[assistantIndex].text += chunk
                    }
                }
            } catch is CancellationError {
                // user closed the panel / sent again — leave partial text as-is
            } catch {
                errorMessage = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            finishStreaming(assistantIndex: assistantIndex)
        }
    }

    private func finishStreaming(assistantIndex: Int) {
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

    /// Confirm the pending result (preview mode, or ⌘⏎).
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

    /// Builds the message array: one system message (global prompt + app context +
    /// output discipline + mode instruction), prior turns, then the new user input
    /// (with selected text folded in on the first turn).
    private func buildMessages(latestUserInput: String) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemContent())]

        // Replay prior completed turns (everything except the two we just appended).
        for entry in transcript.dropLast(2) {
            messages.append(ChatMessage(
                role: entry.role == .user ? "user" : "assistant",
                content: entry.text
            ))
        }

        messages.append(ChatMessage(role: "user", content: userContent(latestUserInput)))
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

    private func userContent(_ input: String) -> String {
        // Only fold the selection / full text into the FIRST user turn.
        guard transcript.dropLast(2).isEmpty else { return input }

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
