import AppKit

// SPM executable: no storyboard/xib. Manual bootstrap.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon; LSUIElement in Info.plist covers bundle case
app.run()
