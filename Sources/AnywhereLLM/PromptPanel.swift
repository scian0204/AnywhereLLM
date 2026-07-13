import AppKit
import SwiftUI

/// Non-activating floating panel hosting the SwiftUI conversation UI. Typing into
/// it must NOT activate our app — the target app stays frontmost so its caret and
/// menu bar are preserved.
///
/// One conversation session per open: `present(context:)` builds a fresh
/// ConversationController, and closing resets it (multi-turn history lives only
/// while the panel is open).
@MainActor
final class PromptPanel: NSPanel {
    private var controller: ConversationController?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            // .nonactivatingPanel: key events reach the panel without activating the app.
            // .titled + .fullSizeContentView hide the titlebar while keeping rounded corners/shadow.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    // Must be true so the panel can receive keyboard input while non-activating.
    override var canBecomeKey: Bool { true }
    // Never becomes main — that would pull activation/menu bar to our app.
    override var canBecomeMain: Bool { false }

    /// Build a session for `context` and swap in the SwiftUI content. Sized to fit.
    func present(context: TargetContext) {
        // 진행 중이던 삽입 스트리밍이 있으면 중단 — 핫키 재입력이 취소 수단.
        self.controller?.cancel()

        let controller = ConversationController(context: context)
        // 모든 콜백에 identity 가드 — 취소로 세션이 교체된 뒤 옛 컨트롤러가
        // 새 패널을 닫거나 스테일 결과를 삽입하는 레이스 차단.
        controller.onApply = { [weak self, weak controller] result in
            guard let self, self.controller === controller else { return }
            self.apply(result, into: context)
        }
        // 삽입 모드: 타이핑 시작 전에 패널을 숨겨 key 포커스를 대상 앱에 돌려준다.
        // 패널이 key인 동안엔 합성 키 이벤트가 패널로 라우팅되어 대상에 닿지 않는다.
        controller.onStreamingInsertStart = { [weak self] in
            self?.orderOut(nil)
        }
        // Insert mode already typed live into the target — just close and reset.
        controller.onStreamingInsertDone = { [weak self, weak controller] in
            guard let self, self.controller === controller else { return }
            self.controller = nil
            self.orderOut(nil)
        }
        // 에러: 숨겨둔 패널을 다시 띄워 메시지를 보여준다.
        controller.onStreamingInsertError = { [weak self, weak controller] in
            guard let self, self.controller === controller else { return }
            self.orderFrontRegardless()
            self.makeKey()
        }
        self.controller = controller

        let host = NSHostingView(rootView: ConversationView(controller: controller))
        host.sizingOptions = [.preferredContentSize] // panel resizes to SwiftUI's fitting size
        contentView = host
    }

    /// Focus is handled by SwiftUI (.onAppear + @FocusState); makeKey suffices here.
    func focusInput() {
        makeFirstResponder(contentView)
    }

    /// Confirmed insert/replace: hide the panel, wait for focus to return to the
    /// target app, then write. Resets the session.
    private func apply(_ result: String, into context: TargetContext) {
        orderOut(nil)
        controller = nil
        // Short delay so the target app is frontmost again before we synthesize keys / set AX.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            TextTargetService.insert(result, into: context)
        }
    }

    /// Close the panel, cancelling any in-flight stream and resetting the session.
    /// 핫키 토글로 닫을 때도 이 경로를 태워 스트림이 백그라운드에서 완주하지 않게 한다.
    func dismiss() {
        controller?.cancel()
        controller = nil
        orderOut(nil)
    }

    /// Esc closes the panel and resets the conversation.
    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
