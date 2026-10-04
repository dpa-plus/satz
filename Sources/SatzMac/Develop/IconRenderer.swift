import AppKit
import SwiftUI

/// Renders the app icon: the brand mark on a tile in the colour family's
/// deep ground. The bundled icon is the DPA+ one:
///
///     satz --icon <folder>.iconset && iconutil -c icns <folder>.iconset
///
/// `make icon` does both and writes Resources/AppIcon.icns. The other
/// families are drawn at runtime, see `AppIcon`.
@MainActor
enum IconRenderer {

    static func write(to folder: String) throws {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let renderer = ImageRenderer(content: tile(for: .dpa))
                renderer.scale = CGFloat(points * scale) / 1024
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
    }

    /// Apple's grid: an 824-point rounded square inside a 1024 canvas, so the
    /// icon sits the same size as every other app in the Dock and Spotlight.
    static func tile(for family: AppTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(family.dark.ground)
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            BrandMark(height: 360, color: family.iconBars)
        }
        .frame(width: 1024, height: 1024)
    }

    /// The icon as an image, for the Dock and the app's bundle.
    static func image(for family: AppTheme, pixels: CGFloat = 1024) -> NSImage? {
        let renderer = ImageRenderer(content: tile(for: family))
        renderer.scale = pixels / 1024
        return renderer.nsImage
    }
}
