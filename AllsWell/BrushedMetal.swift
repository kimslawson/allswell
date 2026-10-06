import AppKit

/// The Panther/Tiger "textured" window look. macOS 10.14 dropped the real
/// texture, so this paints a brushed-aluminum image behind the whole
/// window, titlebar included.
enum BrushedMetal {
    static let defaultsKey = "brushedMetal"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Streaks run horizontally with a bright band down the middle; the
    /// image tiles vertically. Shipped @2x, so one tile is 490pt tall.
    static let texture = NSImage(named: "BrushedMetal")

    /// Light from above: text and glyphs look stamped into the metal when a
    /// white highlight sits 1pt below them.
    static func embossShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.75)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 0
        return shadow
    }
}

/// A recessed control's outline in the metal view's coordinates.
struct SunkenShape {
    var rect: NSRect
    var cornerRadius: CGFloat
}

/// Fills its bounds with brushed metal: the texture stretches across the
/// full width (keeping the bright band centered, like the original's
/// sheen) and repeats down from the top edge, so it doesn't crawl while
/// the window resizes vertically.
final class BrushedMetalView: NSView {
    // Like the original, the whole metal surface drags the window.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Controls that should read as pressed into the metal. Each gets a
    /// 1px shadowed lip along its top and a 1px lit lip along its bottom,
    /// drawn here on the metal just outside the control's own edge.
    var sunkenShapes: [SunkenShape] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let texture = BrushedMetal.texture,
              texture.size.height > 0 else {
            NSColor(white: 0.62, alpha: 1).setFill()
            dirtyRect.fill()
            return
        }
        let tileHeight = texture.size.height
        var y = bounds.maxY - tileHeight
        while y + tileHeight > dirtyRect.minY {
            let tile = NSRect(x: bounds.minX, y: y, width: bounds.width, height: tileHeight)
            if tile.intersects(dirtyRect) {
                texture.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
            }
            y -= tileHeight
        }
        drawSunkenLips()
    }

    /// Fill the shape nudged up 1px in dark and down 1px in light; the
    /// control draws over all but the two crescents peeking out above and
    /// below, which follow its corners.
    private func drawSunkenLips() {
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        for shape in sunkenShapes {
            func path(dy: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: shape.rect.offsetBy(dx: 0, dy: dy),
                             xRadius: shape.cornerRadius, yRadius: shape.cornerRadius)
            }
            NSColor.black.withAlphaComponent(0.45).setFill()
            path(dy: pixel).fill()
            NSColor.white.withAlphaComponent(0.8).setFill()
            path(dy: -pixel).fill()
        }
    }
}
