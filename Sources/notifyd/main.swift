import AppKit

// Menu-bar agent entry point. We configure NSApplication programmatically (no
// Xcode / storyboard). `.accessory` is the runtime equivalent of LSUIElement:
// no Dock icon, no menu bar of its own — it works even when running the bare
// binary during development, before the .app bundle's Info.plist applies.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
