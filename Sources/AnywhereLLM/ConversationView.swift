import SwiftUI

/// The panel's conversation UI. Selection preview (collapsed) on top, transcript
/// in the middle (auto-scrolling), input at the bottom. ⏎ sends, ⇧⏎ newlines,
/// ⌘⏎ confirms a pending result.
struct ConversationView: View {
    @ObservedObject var controller: ConversationController
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = controller.selectionPreview {
                selectionPreview(selection)
            }

            if !controller.transcript.isEmpty {
                transcriptScroll
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputRow

            if controller.pendingResult != nil {
                applyButton
            }
        }
        .padding(12)
        .frame(width: 460)
        .onAppear { inputFocused = true }
    }

    // MARK: - Pieces

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

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // ⏎ sends, ⇧⏎ inserts a newline (default TextField axis: .vertical behavior).
            TextField("무엇이든 물어보세요… (⏎ 전송, ⇧⏎ 줄바꿈, Esc 닫기)",
                      text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            if controller.isStreaming {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var applyButton: some View {
        Button(action: controller.applyPending) {
            Text(controller.hasSelection ? "교체 (⌘⏎)" : "삽입 (⌘⏎)")
                .frame(maxWidth: .infinity)
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
