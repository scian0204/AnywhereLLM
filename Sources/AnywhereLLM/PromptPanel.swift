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
    /// 리사이즈 시 고정할 좌상단 점. NSWindow origin은 좌하단이라 콘텐츠가
    /// 커지면 위로 자라 결과가 화면 위로 밀려난다 — 상단을 고정해 아래로 자라게 한다.
    private var anchoredTopLeft: NSPoint?

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

        // 콘텐츠 성장(결과 스트리밍) 시 상단 고정 + 화면 안 유지. 드래그로 옮기면 앵커 갱신.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAnchoredOnScreen() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchorTopLeft() }
        }
    }

    /// 현재 프레임의 좌상단을 앵커로 저장. 위치 확정 직후(AppDelegate) 호출.
    func anchorTopLeft() {
        anchoredTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
    }

    /// 리사이즈 후 좌상단을 앵커에 되돌리고, 화면(visibleFrame) 밖으로 나가면 밀어넣는다.
    private func keepAnchoredOnScreen() {
        guard let topLeft = anchoredTopLeft else { return }
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - frame.height)
        if let bounds = (screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
            origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        }
        if origin != frame.origin { setFrameOrigin(origin) }
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

        // 창은 스스로 SwiftUI 콘텐츠를 따라 리사이즈되지 않는다 (contentViewController
        // 없는 창에서 sizingOptions 무효). GeometryReader 측정도 창 크기에 갇혀(순환) 불가.
        // layout() 훅에서 fittingSize(제약 무관한 이상 크기)를 받아 직접 리사이즈한다.
        let host = PanelHostingView(rootView: ConversationView(controller: controller))
        host.onLayout = { [weak self, weak host] in
            guard let self, let host else { return }
            let size = host.fittingSize
            // 레이아웃 패스 도중 창 프레임을 바꾸지 않도록 다음 틱으로 미룬다.
            Task { @MainActor in self.resizeToFit(contentSize: size) }
        }
        contentView = host
    }

    /// SwiftUI 콘텐츠 크기에 창을 맞춘다. 좌상단 앵커 고정(아래로 성장) + 화면 클램프.
    private func resizeToFit(contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let target = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        guard target != frame.size else { return }
        let topLeft = anchoredTopLeft ?? NSPoint(x: frame.minX, y: frame.maxY)
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - target.height)
        if let bounds = (screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - target.width))
            origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - target.height))
        }
        setFrame(NSRect(origin: origin, size: target), display: true)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if context.selectedText?.isEmpty == false {
                // 교체: AX setSelectedText가 선택 영역을 정확히 대체 (⌘V 폴백 포함).
                TextTargetService.insert(result, into: context)
            } else {
                // 삽입(무선택): 유니코드 타이핑 — AX setSelectedText가 조용히 무시되는
                // 앱(웹뷰 등)과 ⌘V 폴백의 paste 타이밍 의존을 모두 피한다.
                // 스트리밍 삽입과 같은 검증된 경로. 보안 필드 재확인은 typeText 내부.
                TextTargetService.typeText(result)
            }
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

/// layout() 시점을 알려주는 호스팅 뷰 — SwiftUI 콘텐츠 변경이 NSView 레이아웃으로
/// 내려오는 신뢰 가능한 훅. fittingSize는 이 시점에 갱신된 이상 크기를 반환한다
/// (헤드리스 실측: 콘텐츠 2줄→40줄 교체 시 96→328, docs/progress/15).
private final class PanelHostingView: NSHostingView<ConversationView> {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
