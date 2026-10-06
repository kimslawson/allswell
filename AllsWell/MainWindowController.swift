import AppKit

/// NSPanel with the .utilityWindow style gives the narrow titlebar, small
/// traffic lights, and small centered title; this subclass just lets it
/// behave like a normal main window.
final class MainPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MainWindowController: NSWindowController {
    convenience init() {
        let panel = MainPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = "AllsWell"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 300)
        panel.center()
        self.init(window: panel)
        contentViewController = MainViewController()
        panel.setFrameAutosaveName("AllsWellMainWindow")
        applyTheme()
    }

    /// Brushed metal runs the content under a transparent titlebar so the
    /// metal reads as one continuous surface, and pins the light appearance
    /// (metal never had a dark mode). Off restores the stock window.
    func applyTheme() {
        guard let window,
              let controller = contentViewController as? MainViewController else { return }
        let metal = BrushedMetal.isEnabled
        if metal {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = metal
        window.isMovableByWindowBackground = metal
        window.appearance = metal ? NSAppearance(named: .aqua) : nil
        // The system title can't be embossed; the view draws its own.
        window.titleVisibility = metal ? .hidden : .visible
        controller.setBrushedMetal(metal)
    }

    func ingest(_ urls: [URL]) {
        (contentViewController as? MainViewController)?.ingest(urls)
    }
}
