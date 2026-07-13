import AppKit

/// Non-activating floating panel. Typing into it must NOT activate our app —
/// the target app stays frontmost (its menu bar stays), which is the core
/// requirement being de-risked in this step.
///
/// Real conversation UI lands in step 5; for now it holds a single NSTextField
/// so focus behaviour can be verified by hand.
@MainActor
final class PromptPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            // .nonactivatingPanel: key events go to the panel without activating the app.
            // .titled + .fullSizeContentView give us a titlebar we hide, so the window
            // has standard rounded corners/shadow without a visible chrome bar.
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

        let field = NSTextField(string: "")
        field.placeholderString = "무엇이든 물어보세요… (Esc로 닫기)"
        field.font = .systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        contentView = content
        promptField = field
    }

    private weak var promptField: NSTextField?

    // Must be true so the panel can receive keyboard input while non-activating.
    override var canBecomeKey: Bool { true }
    // Never becomes main — that would pull activation/menu bar to our app.
    override var canBecomeMain: Bool { false }

    /// Esc closes the panel.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    /// Focus the text field after the panel is shown.
    func focusInput() {
        if let field = promptField {
            makeFirstResponder(field)
        }
    }
}
