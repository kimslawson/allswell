import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: Int, CaseIterable {
    case png = 0
    case jpg = 1

    var title: String { self == .png ? "PNG" : "JPG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

struct LoadedImage {
    let cgImage: CGImage
    let suggestedName: String
    let sourceWasHEIC: Bool

    var displayImage: NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

enum ImageLoader {
    static func load(from url: URL) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = image(from: source) else { return nil }
        return LoadedImage(cgImage: cgImage,
                           suggestedName: url.deletingPathExtension().lastPathComponent,
                           sourceWasHEIC: sourceIsHEIC(source))
    }

    static func load(fromPasteboard pasteboard: NSPasteboard) -> LoadedImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                if let loaded = load(from: url) { return loaded }
            }
        }

        let dataTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("com.microsoft.bmp"),
        ]
        if let type = pasteboard.availableType(from: dataTypes),
           let data = pasteboard.data(forType: type),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = image(from: source) {
            return LoadedImage(cgImage: cgImage,
                               suggestedName: timestampName(),
                               sourceWasHEIC: sourceIsHEIC(source))
        }

        // Last resort: anything NSImage can make sense of.
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let nsImage = images.first,
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return LoadedImage(cgImage: cgImage, suggestedName: timestampName(), sourceWasHEIC: false)
        }
        return nil
    }

    static func canLoad(fromPasteboard pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) { return true }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: [:])
    }

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Image \(formatter.string(from: Date()))"
    }

    private static func sourceIsHEIC(_ source: CGImageSource) -> Bool {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    private static func image(from source: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        return normalized(cgImage, exifOrientation: orientation)
    }

    /// Bakes the EXIF orientation into the pixels so exports are upright.
    private static func normalized(_ image: CGImage, exifOrientation: Int) -> CGImage {
        guard (2...8).contains(exifOrientation) else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let swapsAxes = exifOrientation >= 5
        let outW = Int(swapsAxes ? h : w)
        let outH = Int(swapsAxes ? w : h)
        guard let context = CGContext(data: nil,
                                      width: outW,
                                      height: outH,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        switch exifOrientation {
        case 2: // mirrored horizontally
            context.translateBy(x: w, y: 0)
            context.scaleBy(x: -1, y: 1)
        case 3: // rotated 180
            context.translateBy(x: w, y: h)
            context.rotate(by: .pi)
        case 4: // mirrored vertically
            context.translateBy(x: 0, y: h)
            context.scaleBy(x: 1, y: -1)
        case 5: // transposed
            context.translateBy(x: h, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case 6: // rotated 90 CW
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case 7: // transverse
            context.translateBy(x: h, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        case 8: // rotated 90 CCW
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

enum ImageExporter {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let jpegQuality: Double = 0.9

    /// Writes the image and returns the URL it landed at. If `replacing` points at a
    /// previous auto-save of the same image, that file is moved to the Trash first,
    /// so editing the name/format/destination behaves like a rename rather than
    /// littering copies.
    static func export(_ cgImage: CGImage,
                       to directory: URL,
                       name: String,
                       format: ImageFormat,
                       replacing previous: URL?) throws -> URL {
        let data = try encode(cgImage, format: format)
        let proposed = directory
            .appendingPathComponent(sanitize(name))
            .appendingPathExtension(format.fileExtension)

        let fileManager = FileManager.default
        if let previous, previous != proposed, fileManager.fileExists(atPath: previous.path) {
            try? fileManager.trashItem(at: previous, resultingItemURL: nil)
        }
        let url = (previous == proposed) ? proposed : uniqueURL(for: proposed)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func encode(_ cgImage: CGImage, format: ImageFormat) throws -> Data {
        var image = cgImage
        if format == .jpg && hasAlpha(cgImage) {
            image = flattenedOntoWhite(cgImage) ?? cgImage
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let fileType: NSBitmapImageRep.FileType = (format == .jpg) ? .jpeg : .png
        let properties: [NSBitmapImageRep.PropertyKey: Any] =
            (format == .jpg) ? [.compressionFactor: jpegQuality] : [:]
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw ExportError(message: "Could not encode the image as \(format.title).")
        }
        return data
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private static func flattenedOntoWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func sanitize(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-")
        cleaned = cleaned.replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Image" : cleaned
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
