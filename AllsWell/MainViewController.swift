import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class MainViewController: NSViewController, WellViewDelegate {
    private enum DefaultsKey {
        static let destinationPath = "destinationPath"
        static let lenaMode = "lenaMode"
        static let inPlace = "inPlace"

        static func format(for mediaClass: MediaClass) -> String {
            "format.\(mediaClass.rawValue)"
        }
    }

    /// One dropped file and the output we last produced for it. A single
    /// drop is just a batch of one — there is no separate single-file mode.
    private struct BatchItem {
        var media: LoadedMedia
        var savedURL: URL?
        var savedFormatID: String?
        var skipped = false
        var failed = false
    }

    private let registry: ConverterRegistry = {
        var converters: [Converter] = [ImageIOConverter(), AudioFileConverter(), VideoConverter()]
        // If a Homebrew/MacPorts ffmpeg exists, its formats appear by magic.
        if let ffmpeg = FFmpegConverter.probe() {
            converters.append(ffmpeg)
            ConversionLog.shared.info("ffmpeg found at \(ffmpeg.path) — extra formats enabled")
        } else {
            ConversionLog.shared.info("No ffmpeg found — native formats only")
        }
        return ConverterRegistry(converters: converters)
    }()

    private static let orderedClasses: [MediaClass] = [.image, .audio, .video]

    /// Formats whose file extension unambiguously implies the format, so a
    /// batch source already wearing it can be skipped. ALAC and HEVC are
    /// absent on purpose: they share .m4a/.mp4 with AAC and H.264, so
    /// converting to them is always meaningful.
    private static let skipEligibleFormatIDs: Set<String> =
        ["png", "jpg", "m4a", "wav", "flac", "mp3", "ogg", "mp4-h264", "webm"]

    // MARK: UI

    private let well = WellView(frame: .zero)
    private let nameField = NSTextField(string: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let convertLabel = MainViewController.captionLabel("Convert to:")
    private let destinationLabel = MainViewController.captionLabel("Destination:")
    private var classPopups: [MediaClass: NSPopUpButton] = [:]
    private var classIcons: [MediaClass: NSImageView] = [:]
    private var classFormats: [MediaClass: [OutputFormat]] = [:]
    private let inPlaceCheckbox = NSButton(checkboxWithTitle: "In place", target: nil, action: nil)
    private let destinationButton = NSButton(title: "", target: nil, action: nil)
    private let folderImage = NSImage(systemSymbolName: "folder",
                                      accessibilityDescription: "Destination folder")
    private let toast = NSTextField(labelWithString: "")
    private var toastHideWork: DispatchWorkItem?
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private var progressRevealWork: DispatchWorkItem?

    // MARK: Batch state

    private var items: [BatchItem] = []
    private var pendingIndexes: [Int] = []
    private var activeIndex: Int?
    private var activeTask: ConversionTask?
    /// Bumped whenever the in-flight conversion is abandoned, so its
    /// completion (and its temp file) can be recognized and discarded.
    private var taskToken = UUID()
    /// Bumped per ingest; async well previews check it before landing.
    private var ingestGeneration = UUID()
    private var queueTotal = 0
    private var queueDone = 0

    private var inPlace: Bool {
        didSet {
            UserDefaults.standard.set(inPlace, forKey: DefaultsKey.inPlace)
            updateDestinationControls()
        }
    }

    private var destinationURL: URL {
        didSet {
            UserDefaults.standard.set(destinationURL.path, forKey: DefaultsKey.destinationPath)
            updateDestinationControls()
        }
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
        inPlace = defaults.bool(forKey: DefaultsKey.inPlace)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        return label
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 450))

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

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isHidden = true
        view.addSubview(summaryLabel)

        view.addSubview(convertLabel)
        view.addSubview(destinationLabel)

        for mediaClass in Self.orderedClasses {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let formats = registry.outputFormats(for: mediaClass)
            classFormats[mediaClass] = formats
            for format in formats {
                popup.addItem(withTitle: format.title)
            }
            popup.target = self
            popup.action = #selector(formatChanged(_:))
            view.addSubview(popup)
            classPopups[mediaClass] = popup
            selectRememberedFormat(for: mediaClass)

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: Self.symbolName(for: mediaClass),
                                 accessibilityDescription: mediaClass.rawValue)
            icon.contentTintColor = .secondaryLabelColor
            icon.imageScaling = .scaleProportionallyDown
            view.addSubview(icon)
            classIcons[mediaClass] = icon
        }

        inPlaceCheckbox.controlSize = .small
        inPlaceCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        inPlaceCheckbox.target = self
        inPlaceCheckbox.action = #selector(inPlaceToggled(_:))
        view.addSubview(inPlaceCheckbox)

        destinationButton.controlSize = .small
        destinationButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        destinationButton.bezelStyle = .rounded
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

        updateDestinationControls()
        updatePickerVisibility()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAppIcon()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(well)
    }

    // MARK: Layout

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let pad: CGFloat = 10
        let rowHeight: CGFloat = 22
        let labelWidth: CGFloat = 80

        let destRowY = pad
        let convertRowY = destRowY + rowHeight + 8
        let nameRowY = convertRowY + rowHeight + 8
        let wellY = nameRowY + rowHeight + 8

        destinationLabel.frame = NSRect(x: pad, y: destRowY + 3, width: labelWidth, height: 16)
        inPlaceCheckbox.frame = NSRect(x: pad + labelWidth + 4, y: destRowY + 2,
                                       width: 72, height: 18)
        let destButtonX = pad + labelWidth + 4 + 72 + 8
        destinationButton.frame = NSRect(x: destButtonX, y: destRowY,
                                         width: bounds.width - pad - destButtonX,
                                         height: rowHeight)

        convertLabel.frame = NSRect(x: pad, y: convertRowY + 3, width: labelWidth, height: 16)
        // Fixed slots, never moving: image, audio, video — muscle memory.
        for (index, mediaClass) in Self.orderedClasses.enumerated() {
            let iconX = pad + labelWidth + 4 + CGFloat(index) * 88
            classIcons[mediaClass]?.frame = NSRect(x: iconX, y: convertRowY + 3,
                                                   width: 16, height: 16)
            classPopups[mediaClass]?.frame = NSRect(x: iconX + 18, y: convertRowY,
                                                    width: 74, height: rowHeight)
        }

        let nameFrame = NSRect(x: pad, y: nameRowY,
                               width: bounds.width - 2 * pad, height: rowHeight)
        nameField.frame = nameFrame
        summaryLabel.frame = NSRect(x: pad, y: nameRowY + 3,
                                    width: bounds.width - 2 * pad, height: 16)

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

    func ingest(_ urls: [URL]) {
        if urls.count == 1 {
            ingest(urls[0], attempt: 0)
        } else {
            ingest(batch: MediaLoader.loadBatch(from: urls))
        }
    }

    /// Dock drops of promised files (e.g. drags out of a browser) can hand us
    /// a path the source app is still writing; poll briefly before giving up.
    private func ingest(_ url: URL, attempt: Int) {
        let batch = MediaLoader.loadBatch(from: [url])
        if !batch.isEmpty {
            ingest(batch: batch)
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

    func wellView(_ view: WellView, didReceive batch: [LoadedMedia]) {
        ingest(batch: batch)
    }

    private func ingest(batch: [LoadedMedia]) {
        guard !batch.isEmpty else {
            NSSound.beep()
            return
        }
        abandonQueue()
        ingestGeneration = UUID()
        items = batch.map { BatchItem(media: $0) }
        if items.count == 1 {
            nameField.stringValue = items[0].media.suggestedName
        }
        applyFormatSelections()
        updateWellDisplay()
        updateNameRow()
        updatePickerVisibility()
        rebuildQueue(for: nil)
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

    // MARK: Well display

    private func updateWellDisplay() {
        let generation = ingestGeneration
        if items.count == 1 {
            let media = items[0].media
            switch media.payload {
            case .image(let loaded):
                well.image = loaded.displayImage
            case .file(let url):
                well.image = Self.symbolImage(for: media.mediaClass)
                switch media.mediaClass {
                case .image:
                    loadImageThumbnail(for: url, generation: generation)
                case .video:
                    loadVideoThumbnail(for: url, generation: generation)
                case .audio:
                    break
                }
            }
        } else if items.count > 1 {
            let classes = Set(items.map(\.media.mediaClass))
            if classes.count == 1, let only = classes.first {
                well.image = Self.symbolImage(for: only)
            } else {
                well.image = Self.symbolImage(named: "square.stack")
            }
        } else {
            well.image = nil
        }
    }

    private func loadImageThumbnail(for url: URL, generation: UUID) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cgImage = ImageLoader.thumbnail(from: url) else { return }
            DispatchQueue.main.async {
                guard let self, self.ingestGeneration == generation else { return }
                self.well.image = NSImage(cgImage: cgImage,
                                          size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
    }

    /// Swaps the placeholder film glyph for the movie's poster frame once it
    /// can be decoded (it can't for ffmpeg-only containers; the glyph stays).
    private func loadVideoThumbnail(for url: URL, generation: UUID) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 0, preferredTimescale: 600)) {
            [weak self] cgImage, _, _ in
            guard let cgImage else { return }
            DispatchQueue.main.async {
                guard let self, self.ingestGeneration == generation else { return }
                self.well.image = NSImage(cgImage: cgImage,
                                          size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
    }

    private static func symbolName(for mediaClass: MediaClass) -> String {
        switch mediaClass {
        case .image: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        }
    }

    static func symbolImage(for mediaClass: MediaClass) -> NSImage? {
        symbolImage(named: symbolName(for: mediaClass))
    }

    static func symbolImage(named name: String) -> NSImage? {
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

    // MARK: Contextual UI

    /// The picker slots never move; classes absent from the drop just hide.
    /// With nothing dropped yet, all three show as a hint of what the well eats.
    private func updatePickerVisibility() {
        let present: Set<MediaClass> = items.isEmpty
            ? Set(Self.orderedClasses)
            : Set(items.map(\.media.mediaClass))
        for mediaClass in Self.orderedClasses {
            let visible = present.contains(mediaClass)
            classPopups[mediaClass]?.isHidden = !visible
            classIcons[mediaClass]?.isHidden = !visible
        }
    }

    private func updateNameRow() {
        if items.count > 1 {
            nameField.isHidden = true
            summaryLabel.isHidden = false
            summaryLabel.stringValue = batchSummary()
        } else {
            nameField.isHidden = false
            summaryLabel.isHidden = true
        }
    }

    private func batchSummary() -> String {
        var parts: [String] = []
        for mediaClass in Self.orderedClasses {
            let count = items.filter { $0.media.mediaClass == mediaClass }.count
            guard count > 0 else { continue }
            let noun: String
            switch mediaClass {
            case .image: noun = count == 1 ? "image" : "images"
            case .audio: noun = count == 1 ? "song" : "songs"
            case .video: noun = count == 1 ? "movie" : "movies"
            }
            parts.append("\(count) \(noun)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Format selection

    private func selectedFormat(for mediaClass: MediaClass) -> OutputFormat? {
        guard let popup = classPopups[mediaClass],
              let formats = classFormats[mediaClass],
              formats.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return formats[popup.indexOfSelectedItem]
    }

    private func select(formatID: String?, for mediaClass: MediaClass) {
        guard let popup = classPopups[mediaClass],
              let formats = classFormats[mediaClass] else { return }
        if let formatID, let index = formats.firstIndex(where: { $0.id == formatID }) {
            popup.selectItem(at: index)
        } else if !formats.isEmpty {
            popup.selectItem(at: 0)
        }
    }

    private func selectRememberedFormat(for mediaClass: MediaClass) {
        select(formatID: UserDefaults.standard.string(forKey: DefaultsKey.format(for: mediaClass)),
               for: mediaClass)
    }

    /// Re-syncs each present class with its remembered choice, then lets a
    /// unanimous hint (every HEIC, every weird container) override it for
    /// this drop without persisting.
    private func applyFormatSelections() {
        for mediaClass in Self.orderedClasses {
            let classItems = items.filter { $0.media.mediaClass == mediaClass }
            guard !classItems.isEmpty else { continue }
            selectRememberedFormat(for: mediaClass)
            let hints = Set(classItems.map(\.media.preferredFormatID))
            if hints.count == 1, let hint = hints.first, let hintID = hint {
                select(formatID: hintID, for: mediaClass)
            }
        }
    }

    // MARK: Queue

    private func outputDirectory(for media: LoadedMedia) -> URL {
        if inPlace, case .file(let url) = media.payload {
            return url.deletingLastPathComponent()
        }
        // Pasted data has no "place"; it quietly uses the chosen folder.
        return destinationURL
    }

    private func shouldSkip(_ media: LoadedMedia, format: OutputFormat) -> Bool {
        guard items.count > 1,
              Self.skipEligibleFormatIDs.contains(format.id),
              case .file(let url) = media.payload else { return false }
        let ext = url.pathExtension.lowercased()
        if format.id == "jpg" {
            return ext == "jpg" || ext == "jpeg"
        }
        return ext == format.fileExtension
    }

    private func isDirty(_ item: BatchItem, format: OutputFormat) -> Bool {
        guard let savedURL = item.savedURL, item.savedFormatID == format.id else { return true }
        if savedURL.deletingLastPathComponent() != outputDirectory(for: item.media) {
            return true
        }
        if items.count == 1,
           savedURL.deletingPathExtension().lastPathComponent != nameField.stringValue {
            return true
        }
        return false
    }

    /// Recomputes what needs (re)converting and restarts the queue. `classes`
    /// scopes the rebuild to the pickers that changed; nil means everything
    /// (destination change, fresh drop). Items whose output already matches
    /// the current settings are left untouched.
    private func rebuildQueue(for classes: Set<MediaClass>?) {
        let isAffected: (BatchItem) -> Bool = { item in
            classes?.contains(item.media.mediaClass) ?? true
        }

        if let index = activeIndex, isAffected(items[index]) {
            taskToken = UUID() // orphan the in-flight completion
            activeTask?.cancel()
            activeTask = nil
            activeIndex = nil
        }

        var queue: [Int] = []
        for index in items.indices {
            let item = items[index]
            if index == activeIndex { continue }
            if !isAffected(item) {
                if pendingIndexes.contains(index) { queue.append(index) }
                continue
            }
            guard let format = selectedFormat(for: item.media.mediaClass) else { continue }
            if shouldSkip(item.media, format: format) {
                // The previous output no longer reflects the settings; a
                // skipped item has no output at all.
                if let saved = item.savedURL {
                    try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                }
                if !item.skipped {
                    ConversionLog.shared.info(
                        "Skipped \(item.media.suggestedName) — already \(format.title)")
                }
                items[index].savedURL = nil
                items[index].savedFormatID = nil
                items[index].skipped = true
                items[index].failed = false
                continue
            }
            items[index].skipped = false
            if isDirty(items[index], format: format) {
                items[index].failed = false
                queue.append(index)
            }
        }

        pendingIndexes = queue
        queueTotal = queue.count + (activeIndex != nil ? 1 : 0)
        queueDone = 0
        if queueTotal > 0 {
            beginProgressSession()
        }
        if activeIndex == nil {
            processQueue()
        }
    }

    private func processQueue() {
        guard activeIndex == nil else { return }
        while !pendingIndexes.isEmpty {
            let index = pendingIndexes.removeFirst()
            let item = items[index]
            guard let format = selectedFormat(for: item.media.mediaClass),
                  let converter = registry.converter(for: item.media, to: format) else {
                items[index].failed = true
                queueDone += 1
                let target = selectedFormat(for: item.media.mediaClass)?.title ?? "?"
                ConversionLog.shared.error(
                    "\(item.media.suggestedName): no converter can produce \(target) from this file")
                if items.count == 1 {
                    NSSound.beep()
                    showToast("Can’t convert this file")
                }
                continue
            }
            startConversion(index: index, format: format, converter: converter)
            return
        }
        finishQueue()
    }

    private func startConversion(index: Int, format: OutputFormat, converter: Converter) {
        let token = UUID()
        taskToken = token
        activeIndex = index
        let media = items[index].media
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)

        activeTask = converter.convert(media, to: format, destination: tempURL, progress: { [weak self] fraction in
            guard let self, self.taskToken == token else { return }
            self.setBarFraction((Double(self.queueDone) + fraction) / Double(max(self.queueTotal, 1)))
        }, completion: { [weak self] result in
            guard let self, self.taskToken == token else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            self.activeTask = nil
            self.activeIndex = nil
            switch result {
            case .success:
                self.queueDone += 1
                self.place(tempURL, for: index, format: format)
                self.setBarFraction(Double(self.queueDone) / Double(max(self.queueTotal, 1)))
            case .failure(let error):
                try? FileManager.default.removeItem(at: tempURL)
                if case ConversionError.cancelled = error {
                    // Only the user cancels with a live token; stop the queue.
                    self.pendingIndexes = []
                    self.hideProgressUI()
                    self.showToast("Canceled")
                    ConversionLog.shared.info("Canceled — \(media.suggestedName) and the rest of the queue")
                    return
                }
                self.queueDone += 1
                self.items[index].failed = true
                ConversionLog.shared.error(
                    "\(media.suggestedName) → \(format.title): \(error.localizedDescription)")
                if self.items.count == 1 {
                    _ = self.presentError(error)
                }
            }
            self.processQueue()
        })
    }

    private func place(_ tempURL: URL, for index: Int, format: OutputFormat) {
        let item = items[index]
        let name = items.count == 1 ? nameField.stringValue : item.media.suggestedName
        do {
            let url = try FilePlacer.place(tempURL,
                                           into: outputDirectory(for: item.media),
                                           name: name,
                                           fileExtension: format.fileExtension,
                                           replacing: item.savedURL)
            items[index].savedURL = url
            items[index].savedFormatID = format.id
            items[index].failed = false
            ConversionLog.shared.info("Saved \(url.path)")
            if items.count == 1 {
                // Reflect any de-duplication ("name 2") back into the field.
                nameField.stringValue = url.deletingPathExtension().lastPathComponent
                showToast("Saved \(url.lastPathComponent)")
            }
        } catch {
            items[index].failed = true
            ConversionLog.shared.error(
                "\(name): could not save — \(error.localizedDescription)")
            if items.count == 1 {
                _ = presentError(error)
            }
        }
    }

    private func finishQueue() {
        hideProgressUI()
        guard items.count > 1 else { return }
        let saved = items.filter { $0.savedURL != nil }.count
        let skipped = items.filter(\.skipped).count
        let failed = items.filter(\.failed).count
        var parts: [String] = []
        if saved > 0 { parts.append("Saved \(saved)") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if !parts.isEmpty {
            showToast(parts.joined(separator: " · "))
            ConversionLog.shared.info("Batch finished — " + parts.joined(separator: " · "))
        }
    }

    /// Drops everything in flight without any UI side effects (a new drop is
    /// about to replace the state anyway).
    private func abandonQueue() {
        taskToken = UUID()
        activeTask?.cancel()
        activeTask = nil
        activeIndex = nil
        pendingIndexes = []
        hideProgressUI()
    }

    // MARK: Progress UI

    /// Instant saves never see a bar; only a queue that outlives a beat does.
    private func beginProgressSession() {
        guard progressBar.isHidden, progressRevealWork == nil else { return }
        progressBar.isIndeterminate = true
        progressBar.doubleValue = 0
        let reveal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.progressRevealWork = nil
            guard self.activeIndex != nil || !self.pendingIndexes.isEmpty else { return }
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

    private func setBarFraction(_ fraction: Double) {
        if progressBar.isIndeterminate {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
        }
        progressBar.doubleValue = min(max(fraction, 0), 1)
    }

    private func hideProgressUI() {
        progressRevealWork?.cancel()
        progressRevealWork = nil
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true
        cancelButton.isHidden = true
    }

    @objc private func cancelConversion(_ sender: Any?) {
        pendingIndexes = []
        if let activeTask {
            // Completion arrives as .cancelled with a live token and stops the queue.
            activeTask.cancel()
        } else {
            hideProgressUI()
        }
    }

    // MARK: Controls

    @objc private func nameChanged(_ sender: Any?) {
        guard items.count == 1 else { return }
        if let savedURL = items[0].savedURL,
           nameField.stringValue == savedURL.deletingPathExtension().lastPathComponent {
            return
        }
        rebuildQueue(for: [items[0].media.mediaClass])
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let mediaClass = classPopups.first(where: { $0.value === sender })?.key,
              let format = selectedFormat(for: mediaClass) else { return }
        UserDefaults.standard.set(format.id, forKey: DefaultsKey.format(for: mediaClass))
        guard !items.isEmpty else { return }
        rebuildQueue(for: [mediaClass])
    }

    @objc private func inPlaceToggled(_ sender: Any?) {
        inPlace = inPlaceCheckbox.state == .on
        guard !items.isEmpty else { return }
        rebuildQueue(for: nil)
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
            if changed && !self.items.isEmpty {
                self.rebuildQueue(for: nil)
            }
        }
    }

    private func updateDestinationControls() {
        inPlaceCheckbox.state = inPlace ? .on : .off
        destinationButton.isEnabled = !inPlace
        if inPlace {
            // Blanked out, not just dimmed: the folder is irrelevant now.
            destinationButton.image = nil
            destinationButton.title = ""
            destinationButton.toolTip = "Files are saved next to their originals"
        } else {
            destinationButton.image = folderImage
            destinationButton.title = FileManager.default.displayName(atPath: destinationURL.path)
            destinationButton.toolTip = destinationURL.path
        }
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
