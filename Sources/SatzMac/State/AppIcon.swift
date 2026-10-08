import AppKit

/// Keeps the app icon in the chosen colour family.
///
/// The Dock and the app switcher take the icon from the running app. The
/// bundle itself is left alone: a custom Finder icon is a file written into
/// it, which broke the app's code signature. One set by an older satz is
/// taken out again.
@MainActor
enum AppIcon {
    static func apply(_ family: AppTheme) {
        guard let image = IconRenderer.image(for: family) else { return }
        NSApp.applicationIconImage = image
        if FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r") {
            NSWorkspace.shared.setIcon(nil, forFile: Bundle.main.bundlePath, options: [])
        }
    }
}
