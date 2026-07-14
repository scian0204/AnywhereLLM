import SwiftUI

/// The panel UI. Two layouts:
///
/// - **Insert mode** (no selection): just the input box. On send, the reply
///   streams straight into the target text box; the panel shows a "생성 중…" state
///   and closes when done.
/// - **Select mode** (selection present): selection preview + transcript +
///   input + a preview/replace confirm button, with multi-turn.
///
/// ⏎ sends, ⇧⏎ newlines, ⌘⏎ confirms a pending replacement, Esc closes.
struct ConversationView: View {
    @ObservedObject var controller: ConversationController
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if controller.showsTranscriptUI {
                selectMode
            } else {
                insertMode
            }
        }
        .padding(12)
        .frame(width: 460)
        .onAppear { inputFocused = true }
    }

    // MARK: - Insert mode

    // 스트리밍 시작 즉시 패널이 숨으므로 "생성 중" 상태 UI는 그릴 기회가 없다 —
    // 입력창 + (에러 재표시용) 에러 텍스트만 둔다.
    private var insertMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField(placeholder: "무엇이든 물어보세요… (⏎ 전송, ⇧⏎ 줄바꿈, Esc 닫기)")

            if let error = controller.errorMessage { errorText(error) }
        }
    }

    // MARK: - Select mode

    private var selectMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = controller.selectionPreview {
                selectionPreview(selection)
            }

            if !controller.transcript.isEmpty {
                transcriptScroll
            }

            if let error = controller.errorMessage { errorText(error) }

            HStack(alignment: .bottom, spacing: 8) {
                inputField(placeholder: "지시를 입력하세요… (⏎ 전송, ⇧⏎ 줄바꿈, Esc 닫기)")
                if controller.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }

            if controller.pendingResult != nil {
                applyButton
            }
        }
    }

    // MARK: - Shared pieces

    private func inputField(placeholder: String) -> some View {
        TextField(placeholder, text: $input, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($inputFocused)
            .onSubmit(send)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func errorText(_ error: String) -> some View {
        Text(error)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func selectionPreview(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.transcript) { entry in
                        bubble(entry)
                            .frame(maxWidth: .infinity,
                                   alignment: entry.role == .user ? .trailing : .leading)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)
            .onChange(of: controller.transcript.last?.text) {
                if let last = controller.transcript.last {
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func bubble(_ entry: TranscriptEntry) -> some View {
        Text(entry.text.isEmpty && controller.isStreaming ? "…" : entry.text)
            .font(.callout)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                entry.role == .user ? AnyShapeStyle(.tint.opacity(0.15))
                                    : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }

    private var applyButton: some View {
        Button(action: controller.applyPending) {
            Text(controller.hasSelection ? "교체 (⌘⏎)" : "삽입 (⌘⏎)").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func send() {
        let text = input
        input = ""
        controller.send(text)
    }
}
