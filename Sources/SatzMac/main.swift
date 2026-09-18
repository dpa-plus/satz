import AppKit

// No @main: this is an SPM executable, so the entry point is top-level code.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory keeps satz out of the Dock and the app switcher. It is a menu bar
// tool that should never become the foreground application.
application.setActivationPolicy(.accessory)
application.run()
