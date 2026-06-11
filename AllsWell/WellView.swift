import AppKit
import UniformTypeIdentifiers

protocol WellViewDelegate: AnyObject {
    func wellView(_ view: WellView, didReceive batch: [LoadedMedia])
    func wellViewDidDoubleClick(_ view: WellView)
}

/// The titular control: a recessed well that accepts media drags and pastes.
final class WellView: NSView, NSUserInterfaceValidations {
    weak var delegate: WellViewDelegate?

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var placeholder = "Drop or paste a file" {
        didSet { needsDisplay = true }
    }

    private var isDragTarget = false {
        didSet { needsDisplay = true }
    }

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
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = placeholder.size(withAttributes: attributes)
            let point = NSPoint(x: bounds.midX - size.width / 2,
                                y: bounds.midY - size.height / 2)
            placeholder.draw(at: point, withAttributes: attributes)
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
        if event.clickCount == 2 {
            delegate?.wellViewDidDoubleClick(self)
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

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return MediaLoader.canLoad(fromPasteboard: .general)
        }
        return responds(to: item.action)
    }

    // MARK: Dragging

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
        guard pasteboardHasMedia(sender.draggingPasteboard) else { return [] }
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
