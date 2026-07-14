import SwiftUI

/// The panel UI. Two layouts:
///
/// - **Insert mode** (편집 가능 + no selection + immediate): input box + 로딩.
///   첫 토큰이 도착하면 패널이 숨고 응답이 대상 텍스트박스에 직접 타이핑된다.
/// - **Select mode** (selection present, preview, or 보기 전용): selection preview +
///   마지막 응답 결과 블록(대화 버블 없음) + input + 확정 버튼(보기 전용이면 없음 —
///   결과가 패널에 남는다). multi-turn은 히스토리로만 유지되고 화면엔 최신 결과만 보인다.
///   선택이 있으면 첫 턴은 빈 입력 ⏎로도 전송된다 (프롬프트 프로필이 지시 역할).
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
        // 세로 이상 크기 강제 — 이게 있어야 NSHostingView가 intrinsic 높이를 노출해
        // 기본 sizingOptions의 autolayout이 창을 콘텐츠에 자동 추종시킨다 (상단 고정,
        // 아래로 성장 — 실측: docs/progress/16). 수동 리사이즈 금지: autolayout과
        // 싸우면 무한 진동(깜빡임)한다.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { inputFocused = true }
    }

    // MARK: - Insert mode

    // 첫 가시 토큰이 도착할 때까지 패널이 떠 있으므로 로딩 상태를 보여준다.
    // 토큰 도착 직전에 패널이 숨고 대상 텍스트박스 타이핑이 시작된다.
    private var insertMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField(placeholder: "무엇이든 물어보세요… (⏎ 전송, ⇧⏎ 줄바꿈, Esc 닫기)")

            if controller.isStreaming { loadingRow }

            if let error = controller.errorMessage { errorText(error) }
        }
    }

    // MARK: - Select mode

    private var selectMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = controller.selectionPreview {
                selectionPreview(selection)
            }

            if let result = controller.latestAssistantText,
               controller.isStreaming || !result.isEmpty {
                resultView(result)
            }

            if let error = controller.errorMessage { errorText(error) }

            HStack(alignment: .bottom, spacing: 8) {
                inputField(placeholder: controller.hasSelection && controller.transcript.isEmpty
                    ? "지시 입력 — 비워둔 채 ⏎면 프롬프트만으로 요청 (Esc 닫기)"
                    : "지시를 입력하세요… (⏎ 전송, ⇧⏎ 줄바꿈, Esc 닫기)")
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

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("생성 중…").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 결과 미리보기 — 대화 버블 대신 마지막 assistant 응답만 평문 블록으로 표시.
    private func resultView(_ text: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "…" : text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("resultBottom")
            }
            .frame(maxHeight: 280)
            .onChange(of: text) {
                proxy.scrollTo("resultBottom", anchor: .bottom)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
