import AppKit

/// Interactive screen-region capture, mirroring the ⌘⇧4 experience.
///
/// Uses the system `/usr/sbin/screencapture -i` tool: it draws the native
/// crosshair/drag selection UI (and space-to-pick-a-window), writes a PNG, and
/// exits. No custom overlay window, no extra framework. Requires the Screen
/// Recording permission on macOS 10.15+ (checked by the caller before invoking).
enum ScreenCapture {
    /// Run the interactive region capture and return the PNG bytes, or nil if the
    /// user cancelled (Esc — no file is written) or the tool failed.
    ///
    /// Blocks the calling thread while the user drags, so call it off the main
    /// thread (the selection UI is a separate process; only our thread waits).
    static func captureRegion() -> Data? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anywherellm-capture-\(UUID().uuidString).png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive region select, -x no camera sound.
        proc.arguments = ["-i", "-x", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("AnywhereLLM screencapture: launch failed — \(error.localizedDescription)")
            return nil
        }

        defer { try? FileManager.default.removeItem(at: tmp) }
        // Cancelled selection leaves no file; a zero-byte file is also a non-capture.
        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else { return nil }
        return data
    }
}
