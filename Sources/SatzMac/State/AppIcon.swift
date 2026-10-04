import AppKit

/// Keeps the app icon in the chosen colour family.
///
/// The Dock and the app switcher take the icon straight from the running
/// app. Finder, Spotlight and launchers read it from the app's bundle, so
/// for those a custom icon is set on the bundle; DPA+ removes it again and
/// the bundled icon shows.
@MainActor
enum AppIcon {
    static func apply(_ family: AppTheme) {
        guard let image = IconRenderer.image(for: family) else { return }
        NSApp.applicationIconImage = image
        NSWorkspace.shared.setIcon(family == .dpa ? nil : image, forFile: Bundle.main.bundlePath, options: [])
    }
}
