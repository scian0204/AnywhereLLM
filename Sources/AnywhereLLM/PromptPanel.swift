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
        let controller = ConversationController(context: context)
        controller.onApply = { [weak self] result in
            self?.apply(result, into: context)
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

    /// Esc closes the panel and resets the conversation.
    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
        controller = nil
        orderOut(nil)
    }
}
