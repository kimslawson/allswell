import AVFoundation

/// Native video backend: AVAssetExportSession transcodes to MP4 H.264,
/// MP4 HEVC, MOV ProRes, or extracts the audio track to M4A. Containers
/// AVFoundation can't open (MKV, WebM, AVI, …) fall through to the ffmpeg
/// backend, if present.
final class VideoConverter: Converter {
    static let mp4 = OutputFormat(id: "mp4-h264", title: "MP4", fileExtension: "mp4")
    static let hevc = OutputFormat(id: "mp4-hevc", title: "HEVC", fileExtension: "mp4")
    static let prores = OutputFormat(id: "mov-prores", title: "ProRes", fileExtension: "mov")
    static let m4a = OutputFormat(id: "m4a", title: "M4A", fileExtension: "m4a")

    /// Containers AVFoundation reliably opens.
    static let readableExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]

    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat] {
        mediaClass == .video ? [Self.mp4, Self.hevc, Self.prores, Self.m4a] : []
    }

    func canConvert(_ media: LoadedMedia, to format: OutputFormat) -> Bool {
        guard media.mediaClass == .video,
              case .file(let url) = media.payload,
              Self.readableExtensions.contains(url.pathExtension.lowercased())
        else { return false }
        return outputFormats(for: .video).contains(format)
    }

    @discardableResult
    func convert(_ media: LoadedMedia,
                 to format: OutputFormat,
                 destination: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void) -> ConversionTask {
        let task = BasicConversionTask()
        guard case .file(let sourceURL) = media.payload else {
            DispatchQueue.main.async { completion(.failure(ConversionError.unsupported)) }
            return task
        }

        let preset: String
        let fileType: AVFileType
        switch format.id {
        case "mp4-hevc":
            preset = AVAssetExportPresetHEVCHighestQuality
            fileType = .mp4
        case "mov-prores":
            preset = AVAssetExportPresetAppleProRes422LPCM
            fileType = .mov
        case "m4a":
            preset = AVAssetExportPresetAppleM4A
            fileType = .m4a
        default:
            preset = AVAssetExportPresetHighestQuality
            fileType = .mp4
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            DispatchQueue.main.async {
                completion(.failure(ConversionError.failed(
                    "This video can’t be exported as \(format.title).")))
            }
            return task
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        task.onCancel = { [weak session] in
            session?.cancelExport()
        }

        // Export sessions only expose polling, not callbacks, for progress.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak session] _ in
            guard let session else { return }
            progress(Double(session.progress))
        }

        session.exportAsynchronously {
            DispatchQueue.main.async {
                timer.invalidate()
                switch session.status {
                case .completed:
                    completion(.success(()))
                case .cancelled:
                    completion(.failure(ConversionError.cancelled))
                default:
                    let message = session.error?.localizedDescription
                        ?? "The video export failed."
                    completion(.failure(ConversionError.failed(message)))
                }
            }
        }
        return task
    }
}
