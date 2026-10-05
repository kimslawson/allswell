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
}

/// Fills its bounds with brushed metal: the texture stretches across the
/// full width (keeping the bright band centered, like the original's
/// sheen) and repeats down from the top edge, so it doesn't crawl while
/// the window resizes vertically.
final class BrushedMetalView: NSView {
    // Like the original, the whole metal surface drags the window.
    override var mouseDownCanMoveWindow: Bool { true }

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
    }
}
