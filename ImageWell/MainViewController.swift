import AppKit
import UniformTypeIdentifiers

final class MainViewController: NSViewController, ImageWellViewDelegate {
    private enum DefaultsKey {
        static let destinationPath = "destinationPath"
        static let format = "format"
    }

    private let imageWell = ImageWellView(frame: .zero)
    private let nameField = NSTextField(string: "")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destinationButton = NSButton(title: "", target: nil, action: nil)
    private let toast = NSTextField(labelWithString: "")
    private var toastHideWork: DispatchWorkItem?

    private var current: LoadedImage?
    private var lastSavedURL: URL?

    private var destinationURL: URL {
        didSet {
            UserDefaults.standard.set(destinationURL.path, forKey: DefaultsKey.destinationPath)
            updateDestinationButton()
        }
    }

    private var selectedFormat: ImageFormat {
        ImageFormat(rawValue: formatPopup.indexOfSelectedItem) ?? .png
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: DefaultsKey.destinationPath),
           FileManager.default.fileExists(atPath: path) {
            destinationURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            destinationURL = FileManager.default.urls(for: .desktopDirectory,
                                                      in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))

        imageWell.delegate = self
        view.addSubview(imageWell)

        nameField.controlSize = .small
        nameField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.placeholderString = "Filename"
        nameField.target = self
        nameField.action = #selector(nameChanged(_:))
        (nameField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        nameField.lineBreakMode = .byTruncatingMiddle
        view.addSubview(nameField)

        formatPopup.controlSize = .small
        formatPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for format in ImageFormat.allCases {
            formatPopup.addItem(withTitle: format.title)
        }
        let savedFormat = UserDefaults.standard.integer(forKey: DefaultsKey.format)
        formatPopup.selectItem(at: ImageFormat(rawValue: savedFormat)?.rawValue ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        view.addSubview(formatPopup)

        destinationButton.controlSize = .small
        destinationButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        destinationButton.bezelStyle = .rounded
        destinationButton.image = NSImage(systemSymbolName: "folder",
                                          accessibilityDescription: "Destination folder")
        destinationButton.imagePosition = .imageLeading
        (destinationButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        destinationButton.target = self
        destinationButton.action = #selector(chooseDestination(_:))
        view.addSubview(destinationButton)

        toast.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        toast.textColor = .white
        toast.alignment = .center
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        toast.layer?.cornerRadius = 6
        toast.isHidden = true
        view.addSubview(toast)

        updateDestinationButton()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(imageWell)
    }

    // Fields sit beside the well when the window is wide, below it when tall.
    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let pad: CGFloat = 10
        let gap: CGFloat = 8
        let rowHeight: CGFloat = 22

        if bounds.width > bounds.height {
            let columnWidth = max(150, min(210, bounds.width * 0.4))
            let columnX = bounds.maxX - pad - columnWidth
            var y = bounds.maxY - pad - rowHeight
            nameField.frame = NSRect(x: columnX, y: y, width: columnWidth, height: rowHeight)
            y -= rowHeight + gap
            formatPopup.frame = NSRect(x: columnX, y: y, width: columnWidth, height: rowHeight)
            y -= rowHeight + gap
            destinationButton.frame = NSRect(x: columnX, y: y, width: columnWidth, height: rowHeight)
            imageWell.frame = NSRect(x: pad, y: pad,
                                     width: columnX - gap - pad,
                                     height: bounds.height - 2 * pad)
        } else {
            let bottomRowY = pad
            let nameRowY = bottomRowY + rowHeight + gap
            nameField.frame = NSRect(x: pad, y: nameRowY,
                                     width: bounds.width - 2 * pad, height: rowHeight)
            let formatWidth: CGFloat = 74
            formatPopup.frame = NSRect(x: pad, y: bottomRowY,
                                       width: formatWidth, height: rowHeight)
            destinationButton.frame = NSRect(x: pad + formatWidth + gap, y: bottomRowY,
                                             width: bounds.width - 2 * pad - formatWidth - gap,
                                             height: rowHeight)
            let wellY = nameRowY + rowHeight + gap
            imageWell.frame = NSRect(x: pad, y: wellY,
                                     width: bounds.width - 2 * pad,
                                     height: bounds.maxY - pad - wellY)
        }
    }

    // MARK: Intake

    func ingest(_ url: URL) {
        ingest(url, attempt: 0)
    }

    /// Dock drops of promised files (e.g. drags out of a browser) can hand us
    /// a path the source app is still writing; poll briefly before giving up.
    private func ingest(_ url: URL, attempt: Int) {
        if let loaded = ImageLoader.load(from: url) {
            ingest(loaded)
            return
        }
        if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.ingest(url, attempt: attempt + 1)
            }
        } else {
            NSSound.beep()
        }
    }

    func imageWellView(_ view: ImageWellView, didReceive loaded: LoadedImage) {
        ingest(loaded)
    }

    private func ingest(_ loaded: LoadedImage) {
        current = loaded
        lastSavedURL = nil
        imageWell.image = loaded.displayImage
        nameField.stringValue = loaded.suggestedName
        if loaded.sourceWasHEIC {
            formatPopup.selectItem(at: ImageFormat.jpg.rawValue)
        }
        saveCurrentImage()
    }

    // MARK: Saving

    private func saveCurrentImage() {
        guard let current else { return }
        do {
            let url = try ImageExporter.export(current.cgImage,
                                               to: destinationURL,
                                               name: nameField.stringValue,
                                               format: selectedFormat,
                                               replacing: lastSavedURL)
            lastSavedURL = url
            // Reflect any de-duplication ("name 2") back into the field.
            nameField.stringValue = url.deletingPathExtension().lastPathComponent
            showToast("Saved \(url.lastPathComponent)")
        } catch {
            _ = presentError(error)
        }
    }

    @objc private func nameChanged(_ sender: Any?) {
        guard current != nil else { return }
        let newName = nameField.stringValue
        if let lastSavedURL,
           newName == lastSavedURL.deletingPathExtension().lastPathComponent {
            return
        }
        saveCurrentImage()
    }

    @objc private func formatChanged(_ sender: Any?) {
        UserDefaults.standard.set(selectedFormat.rawValue, forKey: DefaultsKey.format)
        guard current != nil else { return }
        if let lastSavedURL, lastSavedURL.pathExtension == selectedFormat.fileExtension {
            return
        }
        saveCurrentImage()
    }

    @objc private func chooseDestination(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let changed = url != self.destinationURL
            self.destinationURL = url
            if changed && self.current != nil {
                self.saveCurrentImage()
            }
        }
    }

    private func updateDestinationButton() {
        destinationButton.title = FileManager.default.displayName(atPath: destinationURL.path)
        destinationButton.toolTip = destinationURL.path
    }

    // MARK: Toast

    private func showToast(_ message: String) {
        toastHideWork?.cancel()
        toast.stringValue = message
        toast.sizeToFit()
        var frame = toast.frame
        frame.size.width += 16
        frame.size.height += 6
        frame.origin.x = imageWell.frame.midX - frame.width / 2
        frame.origin.y = imageWell.frame.minY + 10
        toast.frame = frame

        toast.isHidden = false
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            toast.animator().alphaValue = 1
        }

        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                self.toast.animator().alphaValue = 0
            }, completionHandler: {
                self.toast.isHidden = true
            })
        }
        toastHideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: hide)
    }
}
