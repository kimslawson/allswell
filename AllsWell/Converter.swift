import AppKit
import UniformTypeIdentifiers

enum MediaClass: String {
    case image
    case audio
    case video
}

/// A format the app can save to. `id` is the stable identity used for
/// per-class format memory in UserDefaults; `title` is the popup label.
struct OutputFormat: Equatable {
    let id: String
    let title: String
    let fileExtension: String
}

/// What landed in the well: decoded pixels for images (which may arrive as
/// bare pasteboard data), or a file on disk for audio/video.
enum MediaPayload {
    case image(LoadedImage)
    case file(URL)
}

struct LoadedMedia {
    let payload: MediaPayload
    let mediaClass: MediaClass
    let suggestedName: String
    /// Hostile inputs nudge the picker (HEIC → jpg) without touching the
    /// remembered per-class choice.
    let preferredFormatID: String?
}

enum ConversionError: LocalizedError, Equatable {
    case cancelled
    case unsupported
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The conversion was canceled."
        case .unsupported: return "This file can’t be converted to the selected format."
        case .failed(let message): return message
        }
    }
}

/// Handle for an in-flight conversion.
protocol ConversionTask: AnyObject {
    func cancel()
}

/// Simple shared task: backends flip `isCancelled` checks or override `onCancel`.
final class BasicConversionTask: ConversionTask {
    private let lock = NSLock()
    private var cancelled = false
    var onCancel: (() -> Void)?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        let already = cancelled
        cancelled = true
        lock.unlock()
        if !already { onCancel?() }
    }
}

protocol Converter {
    /// Short engine name for the log ("ImageIO", "AVFoundation", "ffmpeg").
    var engineName: String { get }

    /// Output formats this backend offers for a media class, in menu order.
    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat]

    /// Whether this backend can produce `format` from `media`. A backend may
    /// accept formats it does not advertise (another backend's menu entries).
    func canConvert(_ media: LoadedMedia, to format: OutputFormat) -> Bool

    /// Converts `media` and writes the result to `destination` (a full file
    /// URL, extension included). `progress` (0…1) and `completion` are called
    /// on the main queue. Cancellation completes with `ConversionError.cancelled`.
    @discardableResult
    func convert(_ media: LoadedMedia,
                 to format: OutputFormat,
                 destination: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void) -> ConversionTask
}

/// Aggregates the available backends. Menu contents are the union of what the
/// backends advertise (first occurrence of an id wins the menu slot); actual
/// conversion goes to the first backend that claims the job.
final class ConverterRegistry {
    private let converters: [Converter]

    init(converters: [Converter]) {
        self.converters = converters
    }

    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat] {
        var seen = Set<String>()
        var formats: [OutputFormat] = []
        for converter in converters {
            for format in converter.outputFormats(for: mediaClass) where !seen.contains(format.id) {
                seen.insert(format.id)
                formats.append(format)
            }
        }
        return formats
    }

    func converter(for media: LoadedMedia, to format: OutputFormat) -> Converter? {
        converters.first { $0.canConvert(media, to: format) }
    }
}

/// Classifies incoming files and builds `LoadedMedia` for them.
enum MediaLoader {
    /// UTTypes the app accepts, in any intake path (drag, paste, Dock).
    /// Folders are accepted too and expanded one level deep at load.
    static var acceptedTypes: [UTType] { [.image, .movie, .audio] }

    static var acceptedDragTypes: [UTType] { acceptedTypes + [.folder] }

    static func load(from url: URL) -> LoadedMedia? {
        guard let type = contentType(of: url) else { return nil }
        let suggestedName = url.deletingPathExtension().lastPathComponent
        if type.conforms(to: .image) {
            // Pixels are decoded lazily at convert/preview time, so dropping
            // a folder of hundreds of images stays instant.
            let isHEIC = type.conforms(to: .heic) || type.conforms(to: .heif)
            return LoadedMedia(payload: .file(url),
                               mediaClass: .image,
                               suggestedName: suggestedName,
                               preferredFormatID: isHEIC ? "jpg" : nil)
        }
        if type.conforms(to: .movie) {
            // The HEIC grudge, generalized: hostile containers default the
            // picker to MP4 H.264 instead of the remembered choice.
            let isNativeContainer = VideoConverter.readableExtensions
                .contains(url.pathExtension.lowercased())
            return LoadedMedia(payload: .file(url),
                               mediaClass: .video,
                               suggestedName: suggestedName,
                               preferredFormatID: isNativeContainer ? nil : "mp4-h264")
        }
        if type.conforms(to: .audio) {
            return LoadedMedia(payload: .file(url),
                               mediaClass: .audio,
                               suggestedName: suggestedName,
                               preferredFormatID: nil)
        }
        return nil
    }

    /// Expands folders (top level only — no recursion, so an accidental drop
    /// of a giant tree can't queue thousands of files) and classifies
    /// everything supported, in stable Finder-like name order.
    static func loadBatch(from urls: [URL]) -> [LoadedMedia] {
        var batch: [LoadedMedia] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                let children = ((try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? [])
                    .sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                            == .orderedAscending
                    }
                for child in children {
                    if let media = load(from: child) { batch.append(media) }
                }
            } else if let media = load(from: url) {
                batch.append(media)
            }
        }
        return batch
    }

    static func loadBatch(fromPasteboard pasteboard: NSPasteboard) -> [LoadedMedia] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let batch = loadBatch(from: urls)
            if !batch.isEmpty { return batch }
        }
        // Bare image data (screenshots, copy-image from browsers).
        if let loaded = ImageLoader.load(fromPasteboardData: pasteboard) {
            return [LoadedMedia(payload: .image(loaded),
                                mediaClass: .image,
                                suggestedName: timestampName(),
                                preferredFormatID: loaded.sourceWasHEIC ? "jpg" : nil)]
        }
        return []
    }

    static func canLoad(fromPasteboard pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: acceptedDragTypes.map(\.identifier),
        ]) { return true }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: [:])
    }

    static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Media \(formatter.string(from: Date()))"
    }

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}

/// Moves a finished conversion from its temp location into the destination
/// folder, preserving ImageWell's rename-not-litter semantics: if `previous`
/// points at the last auto-save of the same media, it is trashed first; name
/// collisions get " 2", " 3", … appended.
enum FilePlacer {
    static func place(_ source: URL,
                      into directory: URL,
                      name: String,
                      fileExtension: String,
                      replacing previous: URL?) throws -> URL {
        let proposed = directory
            .appendingPathComponent(sanitize(name))
            .appendingPathExtension(fileExtension)

        let fileManager = FileManager.default
        if let previous, previous != proposed, fileManager.fileExists(atPath: previous.path) {
            try? fileManager.trashItem(at: previous, resultingItemURL: nil)
        }
        let url: URL
        if previous == proposed {
            url = proposed
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } else {
            url = uniqueURL(for: proposed)
        }
        try fileManager.moveItem(at: source, to: url)
        return url
    }

    private static func sanitize(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-")
        cleaned = cleaned.replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "File" : cleaned
    }

    private static func uniqueURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var counter = 2
        while true {
            let candidate = directory
                .appendingPathComponent("\(base) \(counter)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
