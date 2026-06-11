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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = "AllsWell"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 300, height: 240)
        panel.center()
        self.init(window: panel)
        contentViewController = MainViewController()
        panel.setFrameAutosaveName("AllsWellMainWindow")
    }

    func ingest(_ url: URL) {
        (contentViewController as? MainViewController)?.ingest(url)
    }
}
