import AppKit

/// The log window: a filter field, an All/Errors scope, and a read-only,
/// selectable text view. Copy works as expected; ⌘F gets the find bar.
final class LogWindowController: NSWindowController, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let textView = NSTextView()
    private var observer: NSObjectProtocol?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "AllsWell Log"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 200)
        window.center()
        self.init(window: window)
        buildUI()
        observer = NotificationCenter.default.addObserver(
            forName: ConversionLog.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.render()
        }
        render()
        window.setFrameAutosaveName("AllsWellLogWindow")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width
        let barHeight: CGFloat = 34

        let bar = NSView(frame: NSRect(x: 0, y: content.bounds.height - barHeight,
                                       width: width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)

        let scopeWidth: CGFloat = 76
        let clearWidth: CGFloat = 58
        let pad: CGFloat = 8

        searchField.frame = NSRect(x: pad, y: 6,
                                   width: width - pad * 4 - scopeWidth - clearWidth,
                                   height: 22)
        searchField.autoresizingMask = [.width]
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        bar.addSubview(searchField)

        scopePopup.frame = NSRect(x: width - pad * 2 - clearWidth - scopeWidth, y: 6,
                                  width: scopeWidth, height: 22)
        scopePopup.autoresizingMask = [.minXMargin]
        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.addItems(withTitles: ["All", "Errors"])
        scopePopup.target = self
        scopePopup.action = #selector(filterChanged(_:))
        bar.addSubview(scopePopup)

        clearButton.frame = NSRect(x: width - pad - clearWidth, y: 6,
                                   width: clearWidth, height: 22)
        clearButton.autoresizingMask = [.minXMargin]
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearLog(_:))
        bar.addSubview(clearButton)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width,
                                                    height: content.bounds.height - barHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.documentView = textView
        content.addSubview(scrollView)
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) {
        render()
    }

    @objc private func filterChanged(_ sender: Any?) {
        render()
    }

    @objc private func clearLog(_ sender: Any?) {
        ConversionLog.shared.clear()
    }

    private func render() {
        let query = searchField.stringValue
        let errorsOnly = scopePopup.indexOfSelectedItem == 1
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                               weight: .regular)
        let output = NSMutableAttributedString()
        for entry in ConversionLog.shared.entries {
            if errorsOnly && entry.level != .error { continue }
            if !query.isEmpty && !entry.message.localizedCaseInsensitiveContains(query) { continue }
            output.append(NSAttributedString(
                string: Self.timeFormatter.string(from: entry.date) + "  ",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            output.append(NSAttributedString(
                string: entry.message + "\n",
                attributes: [.font: font,
                             .foregroundColor: entry.level == .error
                                 ? NSColor.systemRed : NSColor.labelColor]))
        }
        textView.textStorage?.setAttributedString(output)
        textView.scrollToEndOfDocument(nil)
    }
}
