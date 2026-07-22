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
    @State private var profiles: [PromptProfile] = []
    @State private var activeProfile = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileRow
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
        .onAppear {
            profiles = PromptProfile.loadAll()
            activeProfile = PromptProfile.activeName(in: profiles)
            inputFocused = true
        }
        .onChange(of: activeProfile) { _, _ in
            // 미러 즉시 갱신 — ConversationController는 send마다 systemPrompt를 읽으므로
            // 다음 전송부터 새 프로필이 반영된다.
            PromptProfile.setActive(activeProfile, in: profiles)
        }
    }

    // MARK: - Profile row

    /// 프롬프트 프로필 드롭다운. ⌘P로 열리고, 열린 메뉴는 네이티브 ↑↓·⏎·타이핑 검색을
    /// 지원한다 — 마우스 없이 ⌘P → ↑↓ → ⏎ 흐름 성립.
    private var profileRow: some View {
        HStack(spacing: 6) {
            ProfileDropdown(titles: profiles.map(\.name), selection: $activeProfile)
                .fixedSize()
            Text("⌘P")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Insert mode

    // 첫 가시 토큰이 도착할 때까지 패널이 떠 있으므로 로딩 상태를 보여준다.
    // 토큰 도착 직전에 패널이 숨고 대상 텍스트박스 타이핑이 시작된다.
    private var insertMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField(placeholder: L("input.ask"))

            if controller.isStreaming { loadingRow }

            if let error = controller.errorMessage { errorText(error) }
        }
    }

    // MARK: - Select mode

    private var selectMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = controller.capturedImageData, let image = NSImage(data: data) {
                imageThumbnail(image)
            }
            if let selection = controller.selectionPreview {
                selectionPreview(selection)
            }

            if let result = controller.latestAssistantText,
               controller.isStreaming || !result.isEmpty {
                resultView(result)
            }

            if let error = controller.errorMessage { errorText(error) }

            HStack(alignment: .bottom, spacing: 8) {
                inputField(placeholder: firstTurnPlaceholder)
                if controller.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }

            if controller.pendingResult != nil {
                applyButton
            }
        }
    }

    /// 첫 턴 입력창 placeholder: 이미지·선택은 빈 ⏎ 전송 안내, 그 외는 일반 지시.
    private var firstTurnPlaceholder: String {
        guard controller.transcript.isEmpty else { return L("input.instruct") }
        if controller.hasImage { return L("input.imageFirst") }
        if controller.hasSelection { return L("input.instructFirst") }
        return L("input.instruct")
    }

    // MARK: - Shared pieces

    /// 캡쳐한 이미지 썸네일 — 무엇을 질의 중인지 확인용.
    private func imageThumbnail(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 160, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
    }

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
            Text(L("panel.generating")).font(.callout).foregroundStyle(.secondary)
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
            Text(controller.hasSelection ? L("panel.replace") : L("panel.insert")).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func send() {
        // 수락됐을 때만 입력을 비운다 — 스트리밍 중(또는 빈 요청)엔 controller.send가
        // 거부하므로, 먼저 비우면 사용자가 친 다음 지시가 흔적 없이 사라진다.
        if controller.send(input) { input = "" }
    }
}

// MARK: - Profile dropdown

/// NSPopUpButton 기반 프로필 선택기. SwiftUI Picker는 프로그램적으로 열 수 없어
/// AppKit을 쓴다: 숨은 버튼의 ⌘P가 performClick()으로 메뉴를 연다. 팝업 자체는
/// 포커스를 거부(refusesFirstResponder)해 입력 필드 포커스가 유지되고, 열린
/// NSMenu는 first responder와 무관하게 키보드 내비게이션을 받는다.
private struct ProfileDropdown: View {
    let titles: [String]
    @Binding var selection: String
    @State private var proxy = PopUpProxy()

    var body: some View {
        PopUpButton(titles: titles, selection: $selection, proxy: proxy)
            .overlay(
                Button("") { proxy.button?.performClick(nil) }
                    .keyboardShortcut("p", modifiers: .command)
                    .buttonStyle(.plain)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
    }
}

/// SwiftUI 단축키 버튼에서 AppKit 팝업을 열기 위한 약한 참조 홀더.
@MainActor
private final class PopUpProxy {
    weak var button: NSPopUpButton?
}

private struct PopUpButton: NSViewRepresentable {
    let titles: [String]
    @Binding var selection: String
    let proxy: PopUpProxy

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // 패널 표시 시 입력 필드가 포커스를 가져가야 한다 — 팝업은 key view 순환에서 제외.
        button.refusesFirstResponder = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        proxy.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(withTitle: selection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }

        @objc func changed(_ sender: NSPopUpButton) {
            selection.wrappedValue = sender.titleOfSelectedItem ?? ""
        }
    }
}
