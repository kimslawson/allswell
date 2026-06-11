import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class MainViewController: NSViewController, WellViewDelegate {
    private enum DefaultsKey {
        static let destinationPath = "destinationPath"
        static let lenaMode = "lenaMode"

        static func format(for mediaClass: MediaClass) -> String {
            "format.\(mediaClass.rawValue)"
        }
    }

    private let registry: ConverterRegistry = {
        var converters: [Converter] = [ImageIOConverter(), AudioFileConverter(), VideoConverter()]
        // If a Homebrew/MacPorts ffmpeg exists, its formats appear by magic.
        if let ffmpeg = FFmpegConverter.probe() {
            converters.append(ffmpeg)
        }
        return ConverterRegistry(converters: converters)
    }()

    private let well = WellView(frame: .zero)
    private let nameField = NSTextField(string: "")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destinationButton = NSButton(title: "", target: nil, action: nil)
    private let toast = NSTextField(labelWithString: "")
    private var toastHideWork: DispatchWorkItem?

    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private var progressRevealWork: DispatchWorkItem?

    private var current: LoadedMedia?
    private var availableFormats: [OutputFormat] = []
    private var lastSavedURL: URL?
    private var lastSavedFormatID: String?
    private var activeTask: ConversionTask?
    private var activeTaskID = UUID()

    private var destinationURL: URL {
        didSet {
            UserDefaults.standard.set(destinationURL.path, forKey: DefaultsKey.destinationPath)
            updateDestinationButton()
        }
    }

    private var selectedFormat: OutputFormat? {
        let index = formatPopup.indexOfSelectedItem
        guard availableFormats.indices.contains(index) else { return availableFormats.first }
        return availableFormats[index]
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 420))

        well.delegate = self
        view.addSubview(well)

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
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        view.addSubview(formatPopup)
        reloadFormats(for: .image, preferredID: nil)

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

        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = true
        progressBar.isHidden = true
        view.addSubview(progressBar)

        cancelButton.controlSize = .small
        cancelButton.isBordered = false
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                     accessibilityDescription: "Cancel conversion")
        cancelButton.target = self
        cancelButton.action = #selector(cancelConversion(_:))
        cancelButton.isHidden = true
        view.addSubview(cancelButton)

        updateDestinationButton()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAppIcon()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(well)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let pad: CGFloat = 10
        let gap: CGFloat = 8
        let rowHeight: CGFloat = 22

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
        well.frame = NSRect(x: pad, y: wellY,
                            width: bounds.width - 2 * pad,
                            height: bounds.maxY - pad - wellY)
        layoutProgressUI()
    }

    private func layoutProgressUI() {
        let buttonSize: CGFloat = 16
        let barHeight: CGFloat = 6
        let inset: CGFloat = 14
        let y = well.frame.minY + 12
        progressBar.frame = NSRect(x: well.frame.minX + inset,
                                   y: y + (buttonSize - barHeight) / 2,
                                   width: well.frame.width - 2 * inset - buttonSize - 6,
                                   height: barHeight)
        cancelButton.frame = NSRect(x: progressBar.frame.maxX + 6, y: y,
                                    width: buttonSize, height: buttonSize)
    }

    // MARK: Intake

    func ingest(_ url: URL) {
        ingest(url, attempt: 0)
    }

    /// Dock drops of promised files (e.g. drags out of a browser) can hand us
    /// a path the source app is still writing; poll briefly before giving up.
    private func ingest(_ url: URL, attempt: Int) {
        if let media = MediaLoader.load(from: url) {
            ingest(media)
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

    func wellView(_ view: WellView, didReceive media: LoadedMedia) {
        ingest(media)
    }

    // Easter egg: double-clicking the well swaps the Dock icon's artwork
    // for Lena of image-processing fame, and back.
    func wellViewDidDoubleClick(_ view: WellView) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.lenaMode),
                     forKey: DefaultsKey.lenaMode)
        applyAppIcon()
    }

    private func applyAppIcon() {
        let lenaMode = UserDefaults.standard.bool(forKey: DefaultsKey.lenaMode)
        // nil restores the bundle's regular icon.
        NSApp.applicationIconImage = lenaMode ? NSImage(named: "LenaIcon") : nil
    }

    private func ingest(_ media: LoadedMedia) {
        activeTask?.cancel()
        current = media
        lastSavedURL = nil
        lastSavedFormatID = nil
        well.image = displayImage(for: media)
        if media.mediaClass == .video, case .file(let url) = media.payload {
            loadVideoThumbnail(for: url)
        }
        nameField.stringValue = media.suggestedName
        reloadFormats(for: media.mediaClass, preferredID: media.preferredFormatID)
        convertAndSave()
    }

    /// Swaps the placeholder film glyph for the movie's poster frame once it
    /// can be decoded (it can't for ffmpeg-only containers; the glyph stays).
    private func loadVideoThumbnail(for url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 0, preferredTimescale: 600)) {
            [weak self] cgImage, _, _ in
            guard let cgImage else { return }
            DispatchQueue.main.async {
                guard let self,
                      let media = self.current,
                      case .file(let currentURL) = media.payload,
                      currentURL == url else { return }
                self.well.image = NSImage(cgImage: cgImage,
                                          size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
    }

    private func displayImage(for media: LoadedMedia) -> NSImage? {
        switch media.payload {
        case .image(let loaded):
            return loaded.displayImage
        case .file:
            return Self.symbolImage(for: media.mediaClass)
        }
    }

    static func symbolImage(for mediaClass: MediaClass) -> NSImage? {
        let name: String
        switch mediaClass {
        case .image: name = "photo"
        case .audio: name = "music.note"
        case .video: name = "film"
        }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 88, weight: .light))
        else { return nil }
        let size = symbol.size
        return NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: Formats

    private func reloadFormats(for mediaClass: MediaClass, preferredID: String?) {
        availableFormats = registry.outputFormats(for: mediaClass)
        formatPopup.removeAllItems()
        for format in availableFormats {
            formatPopup.addItem(withTitle: format.title)
        }
        let savedID = UserDefaults.standard.string(forKey: DefaultsKey.format(for: mediaClass))
        let targetID = preferredID ?? savedID
        if let index = availableFormats.firstIndex(where: { $0.id == targetID }) {
            formatPopup.selectItem(at: index)
        } else if !availableFormats.isEmpty {
            formatPopup.selectItem(at: 0)
        }
    }

    // MARK: Conversion

    private func convertAndSave() {
        guard let media = current, let format = selectedFormat else { return }
        guard let converter = registry.converter(for: media, to: format) else {
            NSSound.beep()
            showToast("Can’t convert this file to \(format.title)")
            return
        }

        activeTask?.cancel()
        let taskID = UUID()
        activeTaskID = taskID
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)

        scheduleProgressReveal()
        activeTask = converter.convert(media, to: format, destination: tempURL, progress: { [weak self] fraction in
            guard let self, self.activeTaskID == taskID else { return }
            if self.progressBar.isIndeterminate {
                self.progressBar.stopAnimation(nil)
                self.progressBar.isIndeterminate = false
            }
            self.progressBar.doubleValue = fraction
        }, completion: { [weak self] result in
            guard let self, self.activeTaskID == taskID else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            self.activeTask = nil
            self.hideProgressUI()
            switch result {
            case .success:
                self.place(tempURL, format: format)
            case .failure(let error):
                try? FileManager.default.removeItem(at: tempURL)
                if case ConversionError.cancelled = error {
                    self.showToast("Canceled")
                } else {
                    _ = self.presentError(error)
                }
            }
        })
    }

    private func place(_ tempURL: URL, format: OutputFormat) {
        do {
            let url = try FilePlacer.place(tempURL,
                                           into: destinationURL,
                                           name: nameField.stringValue,
                                           fileExtension: format.fileExtension,
                                           replacing: lastSavedURL)
            lastSavedURL = url
            lastSavedFormatID = format.id
            // Reflect any de-duplication ("name 2") back into the field.
            nameField.stringValue = url.deletingPathExtension().lastPathComponent
            showToast("Saved \(url.lastPathComponent)")
        } catch {
            _ = presentError(error)
        }
    }

    // MARK: Progress UI

    /// Image saves are instant; only conversions that outlive a beat get a bar.
    private func scheduleProgressReveal() {
        progressRevealWork?.cancel()
        progressBar.isIndeterminate = true
        progressBar.doubleValue = 0
        let reveal = DispatchWorkItem { [weak self] in
            guard let self, self.activeTask != nil else { return }
            self.layoutProgressUI()
            self.progressBar.isHidden = false
            self.cancelButton.isHidden = false
            if self.progressBar.isIndeterminate {
                self.progressBar.startAnimation(nil)
            }
        }
        progressRevealWork = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: reveal)
    }

    private func hideProgressUI() {
        progressRevealWork?.cancel()
        progressRevealWork = nil
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true
        cancelButton.isHidden = true
    }

    @objc private func cancelConversion(_ sender: Any?) {
        activeTask?.cancel()
    }

    // MARK: Controls

    @objc private func nameChanged(_ sender: Any?) {
        guard current != nil else { return }
        let newName = nameField.stringValue
        if let lastSavedURL,
           newName == lastSavedURL.deletingPathExtension().lastPathComponent {
            return
        }
        convertAndSave()
    }

    @objc private func formatChanged(_ sender: Any?) {
        guard let format = selectedFormat else { return }
        let mediaClass = current?.mediaClass ?? .image
        UserDefaults.standard.set(format.id, forKey: DefaultsKey.format(for: mediaClass))
        guard current != nil else { return }
        if lastSavedURL != nil, lastSavedFormatID == format.id {
            return
        }
        convertAndSave()
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
                self.convertAndSave()
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
        frame.origin.x = well.frame.midX - frame.width / 2
        frame.origin.y = well.frame.minY + 10
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
