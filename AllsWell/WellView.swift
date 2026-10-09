import AppKit
import UniformTypeIdentifiers

protocol WellViewDelegate: AnyObject {
    func wellView(_ view: WellView, didReceive batch: [LoadedMedia])
    func wellViewDidDoubleClick(_ view: WellView)
    func wellView(_ view: WellView, didCopy urls: [URL])
    func wellViewDidRequestClear(_ view: WellView)
    func wellViewDidRequestOpen(_ view: WellView)
}

/// The titular control: a recessed well that accepts media drags and pastes.
final class WellView: NSView, NSUserInterfaceValidations {
    weak var delegate: WellViewDelegate?

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// Converted outputs currently on disk. Non-empty makes the proxy image
    /// draggable back out of the well, into Finder or any other app.
    var draggableFileURLs: [URL] = [] {
        didSet { updateHoverButtons() }
    }

    /// Whether anything is loaded. Set by the owner; shows the clear button
    /// and turns off click-to-choose.
    var hasContent = false {
        didSet { updateHoverButtons() }
    }

    /// Empty-state hints, drawn as a centered bulleted list.
    var placeholderLines = ["Drop or paste files or folders here",
                            "Click to choose files or folders"] {
        didSet { needsDisplay = true }
    }

    private var isDragTarget = false {
        didSet { needsDisplay = true }
    }

    private var mouseDownEvent: NSEvent?

    /// A click on the empty well opens the chooser only once the double-click
    /// window passes, so the double-click easter egg still works there.
    private var pendingOpen: DispatchWorkItem?

    private var hoverArea: NSTrackingArea?

    private var isHovering = false {
        didSet { updateHoverButtons() }
    }

    /// Hover affordance in the upper-left corner, mirroring Copy: empties the
    /// well. Saved outputs stay on disk.
    private let clearButton: NSButton = {
        let button = HoverGlyphButton()
        button.image = NSImage(systemSymbolName: "xmark",
                               accessibilityDescription: "Remove")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Remove from the well"
        button.isHidden = true
        return button
    }()

    /// Hover affordance in the upper-right corner: one click copies the
    /// converted file(s), same as Edit ▸ Copy.
    private let copyButton: NSButton = {
        let button = HoverGlyphButton()
        button.image = NSImage(systemSymbolName: "doc.on.doc",
                               accessibilityDescription: "Copy")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Copy converted file"
        button.isHidden = true
        return button
    }()

    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .tiff, .png]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Media well")
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        addSubview(copyButton)
        clearButton.target = self
        clearButton.action = #selector(clearWell(_:))
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Drawing

    private func wellPath() -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = wellPath()

        NSColor.textBackgroundColor.setFill()
        path.fill()

        // Subtle inner shadow along the top edge for the recessed-well look.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let shadeHeight: CGFloat = 7
        let topRect = NSRect(x: bounds.minX, y: bounds.maxY - shadeHeight,
                             width: bounds.width, height: shadeHeight)
        let gradient = NSGradient(starting: NSColor.black.withAlphaComponent(0.0),
                                  ending: NSColor.black.withAlphaComponent(0.08))
        gradient?.draw(in: topRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        if let image, image.size.width > 0, image.size.height > 0 {
            let available = bounds.insetBy(dx: 8, dy: 8)
            let scale = min(available.width / image.size.width,
                            available.height / image.size.height,
                            1)
            let drawSize = NSSize(width: image.size.width * scale,
                                  height: image.size.height * scale)
            let drawRect = NSRect(x: available.midX - drawSize.width / 2,
                                  y: available.midY - drawSize.height / 2,
                                  width: drawSize.width,
                                  height: drawSize.height)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            drawPlaceholder()
        }

        if isDragTarget {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// The bulleted hints as one left-aligned block, centered in the well,
    /// with wrapped lines hanging past their bullet.
    private func drawPlaceholder() {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let indent = ceil(("\u{2022}  " as NSString).size(withAttributes: [.font: font]).width)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        style.headIndent = indent
        style.paragraphSpacing = 3
        let text = NSAttributedString(
            string: placeholderLines.map { "\u{2022}\t" + $0 }.joined(separator: "\n"),
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
        let maxWidth = bounds.width - 32
        let size = text.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin]).size
        let width = min(ceil(size.width) + 1, maxWidth)
        let height = ceil(size.height)
        text.draw(with: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                               width: width, height: height),
                  options: [.usesLineFragmentOrigin])
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 24
        let inset: CGFloat = 6
        copyButton.frame = NSRect(x: bounds.maxX - side - inset,
                                  y: bounds.maxY - side - inset,
                                  width: side, height: side)
        clearButton.frame = NSRect(x: bounds.minX + inset,
                                   y: bounds.maxY - side - inset,
                                   width: side, height: side)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        if let window {
            isHovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateHoverButtons() {
        copyButton.isHidden = !(isHovering && !existingFileURLs.isEmpty)
        clearButton.isHidden = !(isHovering && hasContent)
    }

    // Dragging the well drags its file out, never the window (which a
    // movable-by-background brushed metal window would otherwise do).
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pendingOpen?.cancel()
        pendingOpen = nil
        if event.clickCount == 2 {
            delegate?.wellViewDidDoubleClick(self)
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent = mouseDownEvent else { return }
        let down = downEvent.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - down.x, now.y - down.y) > 4 else { return }
        mouseDownEvent = nil
        beginDragOut(with: downEvent)
    }

    override func mouseUp(with event: NSEvent) {
        // Still set means the press never turned into a drag.
        let wasClick = mouseDownEvent != nil
        mouseDownEvent = nil
        guard wasClick, event.clickCount == 1, !hasContent,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        let open = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingOpen = nil
            guard !self.hasContent else { return }
            self.delegate?.wellViewDidRequestOpen(self)
        }
        pendingOpen = open
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: open)
    }

    override func accessibilityPerformPress() -> Bool {
        guard !hasContent else { return false }
        delegate?.wellViewDidRequestOpen(self)
        return true
    }

    // MARK: Clear

    @objc func clearWell(_ sender: Any?) {
        guard hasContent else {
            NSSound.beep()
            return
        }
        delegate?.wellViewDidRequestClear(self)
    }

    /// Delete and Forward Delete empty the well, like the X.
    override func keyDown(with event: NSEvent) {
        if event.specialKey == .delete || event.specialKey == .deleteForward, hasContent {
            clearWell(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        wellPath().fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Paste

    @objc func paste(_ sender: Any?) {
        let batch = MediaLoader.loadBatch(fromPasteboard: .general)
        if !batch.isEmpty {
            delegate?.wellView(self, didReceive: batch)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Copy

    /// Converted outputs that still exist on disk.
    private var existingFileURLs: [URL] {
        draggableFileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Puts the converted file(s) on the clipboard as file URLs, the way
    /// Finder's Copy does. A lone image also carries its bytes, so apps that
    /// only take pasted image data (Messages, chat apps, editors) get pixels.
    @objc func copy(_ sender: Any?) {
        let urls = existingFileURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        Self.writeFiles(urls, to: .general)
        delegate?.wellView(self, didCopy: urls)
    }

    /// Shared by Copy and the auto-copy-to-clipboard option.
    static func writeFiles(_ urls: [URL], to pasteboard: NSPasteboard) {
        var pasteboardItems: [NSPasteboardItem] = []
        for url in urls {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if urls.count == 1,
               let type = UTType(filenameExtension: url.pathExtension),
               type.conforms(to: .image),
               let data = try? Data(contentsOf: url) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
                if type != .png, type != .tiff,
                   let tiff = NSImage(data: data)?.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
            }
            pasteboardItems.append(item)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return MediaLoader.canLoad(fromPasteboard: .general)
        }
        if item.action == #selector(copy(_:)) {
            return !existingFileURLs.isEmpty
        }
        return responds(to: item.action)
    }

    // MARK: Dragging out

    /// Starts a drag of the converted file(s) the well currently represents.
    /// A single item drags as the proxy image itself; batches drag as a stack
    /// of file icons.
    private func beginDragOut(with event: NSEvent) {
        let urls = existingFileURLs
        guard !urls.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)

        var draggingItems: [NSDraggingItem] = []
        for url in urls {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let badge: NSImage
            if urls.count == 1, let image, image.size.width > 0, image.size.height > 0 {
                badge = image
            } else {
                badge = NSWorkspace.shared.icon(forFile: url.path)
            }
            let maxSide: CGFloat = 96
            let scale = min(maxSide / max(badge.size.width, badge.size.height), 1)
            let size = NSSize(width: badge.size.width * scale,
                              height: badge.size.height * scale)
            item.setDraggingFrame(NSRect(x: location.x - size.width / 2,
                                         y: location.y - size.height / 2,
                                         width: size.width, height: size.height),
                                  contents: badge)
            draggingItems.append(item)
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    // MARK: Dragging in

    private func pasteboardHasMedia(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: MediaLoader.acceptedDragTypes.map(\.identifier),
        ]) { return true }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: [:]) { return true }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: [:]) { return true }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A drag that started here is the converted file leaving; re-ingesting
        // it on a wobbly drop would be nonsense.
        guard (sender.draggingSource as? WellView) !== self,
              pasteboardHasMedia(sender.draggingPasteboard) else { return [] }
        isDragTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTarget = false
        let pasteboard = sender.draggingPasteboard

        let batch = MediaLoader.loadBatch(fromPasteboard: pasteboard)
        if !batch.isEmpty {
            delegate?.wellView(self, didReceive: batch)
            return true
        }

        // Drags from apps like Photos and Safari deliver file promises.
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver],
           let receiver = receivers.first {
            let dropDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dropDirectory,
                                                     withIntermediateDirectories: true)
            receiver.receivePromisedFiles(atDestination: dropDirectory,
                                          options: [:],
                                          operationQueue: promiseQueue) { url, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self, error == nil,
                          let media = MediaLoader.load(from: url) else { return }
                    self.delegate?.wellView(self, didReceive: [media])
                }
            }
            return true
        }
        return false
    }
}

extension WellView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Borderless glyph button on a soft rounded backing, so it stays legible
/// over whatever image the well is showing.
private final class HoverGlyphButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let backing = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        backing.fill()
        NSColor.separatorColor.setStroke()
        backing.lineWidth = 0.5
        backing.stroke()
        super.draw(dirtyRect)
    }
}
