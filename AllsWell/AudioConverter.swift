import AVFoundation

/// Native audio backend: decodes with AVAudioFile (WAV, AIFF, CAF, MP3, M4A,
/// FLAC, …) and re-encodes to M4A/AAC, WAV, FLAC, or ALAC, streaming in
/// chunks so long files report progress and cancel promptly.
final class AudioFileConverter: Converter {
    let engineName = "AVFoundation"

    static let m4a = OutputFormat(id: "m4a", title: "M4A", fileExtension: "m4a")
    static let wav = OutputFormat(id: "wav", title: "WAV", fileExtension: "wav")
    static let flac = OutputFormat(id: "flac", title: "FLAC", fileExtension: "flac")
    static let alac = OutputFormat(id: "alac", title: "ALAC", fileExtension: "m4a")

    /// Containers AVAudioFile reliably opens; anything else falls through to
    /// the ffmpeg backend, if present.
    private static let readableExtensions: Set<String> = [
        "wav", "wave", "bwf", "aif", "aiff", "aifc", "caf",
        "mp3", "m4a", "m4b", "m4r", "aac", "adts",
        "flac", "alac", "au", "snd", "sd2", "amr", "3ga",
    ]

    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat] {
        mediaClass == .audio ? [Self.m4a, Self.wav, Self.flac, Self.alac] : []
    }

    func canConvert(_ media: LoadedMedia, to format: OutputFormat) -> Bool {
        guard media.mediaClass == .audio,
              case .file(let url) = media.payload,
              Self.readableExtensions.contains(url.pathExtension.lowercased())
        else { return false }
        return outputFormats(for: .audio).contains(format)
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
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                try Self.transcode(from: sourceURL, to: destination,
                                   format: format, task: task, progress: progress)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        return task
    }

    private static func transcode(from sourceURL: URL,
                                  to destination: URL,
                                  format: OutputFormat,
                                  task: BasicConversionTask,
                                  progress: @escaping (Double) -> Void) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw ConversionError.failed("Could not read the audio file.")
        }
        let pcmFormat = input.processingFormat
        let totalFrames = input.length
        let settings = outputSettings(for: format,
                                      sampleRate: pcmFormat.sampleRate,
                                      channels: pcmFormat.channelCount)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings)
        } catch {
            throw ConversionError.failed("Could not create a \(format.title) encoder for this audio.")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 32768) else {
            throw ConversionError.failed("Could not allocate an audio buffer.")
        }
        var lastReported = 0.0
        while input.framePosition < input.length {
            if task.isCancelled { throw ConversionError.cancelled }
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            if totalFrames > 0 {
                let fraction = Double(input.framePosition) / Double(totalFrames)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    DispatchQueue.main.async { progress(fraction) }
                }
            }
        }
    }

    private static func outputSettings(for format: OutputFormat,
                                       sampleRate: Double,
                                       channels: AVAudioChannelCount) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        switch format.id {
        case "wav":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case "flac":
            settings[AVFormatIDKey] = kAudioFormatFLAC
        case "alac":
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
        default: // m4a
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        }
        return settings
    }
}
