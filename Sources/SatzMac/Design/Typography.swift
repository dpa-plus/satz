import CoreText
import SwiftUI

/// The DPA+ type set: Bitter for headings, Source Sans 3 for everything read,
/// IBM Plex Mono for small figures such as times.
///
/// The fonts ship inside the app as WOFF2 files (Resources/Fonts, all under the
/// SIL Open Font License) and are registered for this process only at launch,
/// so nothing is installed on the user's Mac. If registration ever fails the
/// names below simply fall back to the system font.
enum Typography {

    static func registerBundledFonts() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }

        for file in files where file.pathExtension == "woff2" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
                Log.note("font not registered: \(file.lastPathComponent)")
            }
        }
    }

    /// Bitter. The variable font registers one PostScript name per weight.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom(bitter(weight), size: size)
    }

    /// Source Sans 3.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(sourceSans(weight), size: size)
    }

    /// IBM Plex Mono. Shipped in two weights only.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium", size: size)
    }

    private static func bitter(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "Bitter-Bold"
        case .semibold: "Bitter-SemiBold"
        case .medium: "Bitter-Medium"
        default: "Bitter-Regular"
        }
    }

    private static func sourceSans(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "SourceSans3-Roman_Bold"
        case .semibold: "SourceSans3-Roman_SemiBold"
        case .medium: "SourceSans3-Roman_Medium"
        default: "SourceSans3-Roman_Regular"
        }
    }
}
