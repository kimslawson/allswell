import AppKit
import CoreImage

/// The Panther/Tiger "textured" window look, rebuilt by hand: macOS 10.14
/// dropped the real texture, so this generates one with the classic recipe
/// (grayscale noise smeared by a long horizontal motion blur) and paints it
/// behind the whole window, titlebar included.
enum BrushedMetal {
    static let defaultsKey = "brushedMetal"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Mid-gray metal with fine horizontal streaks, `pixelSize` pixels big.
    static func texture(pixelSize: CGSize) -> CGImage? {
        let extent = CGRect(origin: .zero, size: pixelSize)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let gray = noise.cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        // Clamp first so the blur doesn't pull transparent black in at the edges.
        let streaks = gray.clampedToExtent()
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 40,
                                                         kCIInputAngleKey: 0])
            .cropped(to: extent)
        // A long blur averages the noise down to ~0.5 ± a few percent; scale
        // that variation back up around the metal's base gray.
        let base: CGFloat = 0.72
        let amount: CGFloat = 1.6
        let toned = streaks.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: base - 0.5 * amount, y: base - 0.5 * amount,
                                        z: base - 0.5 * amount, w: 0),
        ])
        // No color management: the values above are the sRGB grays we want.
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        return context.createCGImage(toned, from: extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Fills its bounds with brushed metal. The texture is drawn 1:1 (never
/// stretched, which would fatten the streaks) and pinned to the top edge so
/// it doesn't crawl while the window resizes; it regrows in coarse steps.
final class BrushedMetalView: NSView {
    private var texture: CGImage?
    private var textureScale: CGFloat = 0

    // Like the original, the whole metal surface drags the window.
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        texture = nil
        needsDisplay = true
    }

    private func ensureTexture() {
        let scale = window?.backingScaleFactor ?? 2
        let needed = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if let texture, textureScale == scale,
           CGFloat(texture.width) >= needed.width, CGFloat(texture.height) >= needed.height {
            return
        }
        let step: CGFloat = 512
        let size = CGSize(width: ceil(needed.width / step) * step,
                          height: ceil(needed.height / step) * step)
        texture = BrushedMetal.texture(pixelSize: size)
        textureScale = scale
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureTexture()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let texture {
            let w = CGFloat(texture.width) / textureScale
            let h = CGFloat(texture.height) / textureScale
            context.draw(texture, in: CGRect(x: 0, y: bounds.maxY - h, width: w, height: h))
        } else {
            NSColor(white: 0.72, alpha: 1).setFill()
            bounds.fill()
        }
        // The sheen: brighter toward the top, as if lit from above.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.28),
                   ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: bounds, angle: -90)
        NSGradient(starting: NSColor.black.withAlphaComponent(0),
                   ending: NSColor.black.withAlphaComponent(0.08))?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.4),
                  angle: -90)
    }
}
