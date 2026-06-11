import AppKit
import ImageIO
import UniformTypeIdentifiers

struct LoadedImage {
    let cgImage: CGImage
    let sourceWasHEIC: Bool

    var displayImage: NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

enum ImageLoader {
    static func load(from url: URL) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = image(from: source) else { return nil }
        return LoadedImage(cgImage: cgImage, sourceWasHEIC: sourceIsHEIC(source))
    }

    /// Bare image data on the pasteboard (no file URL): screenshots,
    /// copy-image from browsers, and the like.
    static func load(fromPasteboardData pasteboard: NSPasteboard) -> LoadedImage? {
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
            return LoadedImage(cgImage: cgImage, sourceWasHEIC: sourceIsHEIC(source))
        }

        // Last resort: anything NSImage can make sense of.
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let nsImage = images.first,
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return LoadedImage(cgImage: cgImage, sourceWasHEIC: false)
        }
        return nil
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

/// The original ImageWell backend: ImageIO/AppKit encoding to PNG or JPG.
final class ImageIOConverter: Converter {
    static let png = OutputFormat(id: "png", title: "PNG", fileExtension: "png")
    static let jpg = OutputFormat(id: "jpg", title: "JPG", fileExtension: "jpg")

    static let jpegQuality: Double = 0.9

    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat] {
        mediaClass == .image ? [Self.png, Self.jpg] : []
    }

    func canConvert(_ media: LoadedMedia, to format: OutputFormat) -> Bool {
        guard case .image = media.payload else { return false }
        return outputFormats(for: .image).contains(format)
    }

    @discardableResult
    func convert(_ media: LoadedMedia,
                 to format: OutputFormat,
                 destination: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void) -> ConversionTask {
        let task = BasicConversionTask()
        guard case .image(let loaded) = media.payload else {
            DispatchQueue.main.async { completion(.failure(ConversionError.unsupported)) }
            return task
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                if task.isCancelled { throw ConversionError.cancelled }
                let data = try Self.encode(loaded.cgImage, format: format)
                try data.write(to: destination, options: .atomic)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        return task
    }

    private static func encode(_ cgImage: CGImage, format: OutputFormat) throws -> Data {
        var image = cgImage
        if format == jpg && hasAlpha(cgImage) {
            image = flattenedOntoWhite(cgImage) ?? cgImage
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let fileType: NSBitmapImageRep.FileType = (format == jpg) ? .jpeg : .png
        let properties: [NSBitmapImageRep.PropertyKey: Any] =
            (format == jpg) ? [.compressionFactor: jpegQuality] : [:]
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw ConversionError.failed("Could not encode the image as \(format.title).")
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
}
