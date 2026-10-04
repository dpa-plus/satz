import AppKit
import SwiftUI

/// Renders the app icon: the brand mark in DPA+ orange on a petrol tile.
///
///     satz --icon <folder>.iconset && iconutil -c icns <folder>.iconset
///
/// `make icon` does both and writes Resources/AppIcon.icns.
@MainActor
enum IconRenderer {

    static func write(to folder: String) throws {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let renderer = ImageRenderer(content: tile)
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
    private static var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Color(hex: 0x16303C))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            BrandMark(height: 360, color: Color(hex: 0xFF6100))
        }
        .frame(width: 1024, height: 1024)
    }
}
