import AVFoundation
import Foundation

/// Optional backend that shells out to a Homebrew/MacPorts ffmpeg if one is
/// installed. When present, formats macOS can't encode (MP3, OGG, …) simply
/// appear in the picker; when absent, they don't exist and nothing hints
/// otherwise. It also accepts the native backends' formats, so sources AVF
/// can't read (OGG in, say) still convert to M4A or FLAC.
final class FFmpegConverter: Converter {
    static let mp3 = OutputFormat(id: "mp3", title: "MP3", fileExtension: "mp3")
    static let ogg = OutputFormat(id: "ogg", title: "OGG", fileExtension: "ogg")

    private let executableURL: URL

    private init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Probes the usual install locations at launch; nil means no ffmpeg.
    static func probe() -> FFmpegConverter? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return FFmpegConverter(executableURL: URL(fileURLWithPath: path))
        }
        return nil
    }

    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat] {
        mediaClass == .audio ? [Self.mp3, Self.ogg] : []
    }

    func canConvert(_ media: LoadedMedia, to format: OutputFormat) -> Bool {
        guard case .file = media.payload else { return false }
        return Self.encoderArguments(for: media.mediaClass, formatID: format.id) != nil
    }

    /// Codec arguments per (media class, format). Includes the native
    /// backends' formats so ffmpeg can be the fallback reader for them.
    private static func encoderArguments(for mediaClass: MediaClass, formatID: String) -> [String]? {
        guard mediaClass == .audio else { return nil }
        switch formatID {
        case "mp3": return ["-codec:a", "libmp3lame", "-q:a", "1"]
        case "ogg": return ["-codec:a", "libvorbis", "-q:a", "6"]
        case "m4a": return ["-codec:a", "aac", "-b:a", "256k"]
        case "wav": return ["-codec:a", "pcm_s16le"]
        case "flac": return ["-codec:a", "flac"]
        case "alac": return ["-codec:a", "alac"]
        default: return nil
        }
    }

    @discardableResult
    func convert(_ media: LoadedMedia,
                 to format: OutputFormat,
                 destination: URL,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void) -> ConversionTask {
        let task = BasicConversionTask()
        guard case .file(let sourceURL) = media.payload,
              let codecArguments = Self.encoderArguments(for: media.mediaClass, formatID: format.id)
        else {
            DispatchQueue.main.async { completion(.failure(ConversionError.unsupported)) }
            return task
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-hide_banner", "-nostdin", "-y",
                             "-i", sourceURL.path,
                             "-progress", "pipe:1", "-nostats"]
            + codecArguments
            + [destination.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Total duration comes from ffmpeg's own stream header on stderr;
        // out_time on the -progress pipe divided by it is the fraction done.
        var durationSeconds: Double?
        var stderrTail = ""
        stderr.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8),
                  !text.isEmpty else { return }
            stderrTail = String((stderrTail + text).suffix(4096))
            if durationSeconds == nil,
               let duration = Self.parseDuration(from: stderrTail) {
                durationSeconds = duration
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8),
                  !text.isEmpty else { return }
            guard let total = durationSeconds, total > 0,
                  let outTime = Self.parseOutTime(from: text) else { return }
            let fraction = min(max(outTime / total, 0), 1)
            DispatchQueue.main.async { progress(fraction) }
        }

        task.onCancel = { [weak process] in
            process?.terminate()
        }
        process.terminationHandler = { process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let result: Result<Void, Error>
            if task.isCancelled {
                result = .failure(ConversionError.cancelled)
            } else if process.terminationStatus == 0 {
                result = .success(())
            } else {
                let lastLine = stderrTail
                    .split(separator: "\n")
                    .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .map(String.init) ?? "ffmpeg exited with status \(process.terminationStatus)."
                result = .failure(ConversionError.failed(lastLine))
            }
            DispatchQueue.main.async { completion(result) }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(ConversionError.failed("Could not launch ffmpeg.")))
            }
        }
        return task
    }

    // MARK: Output parsing

    /// "  Duration: 00:03:25.46, start: …" → 205.46
    private static func parseDuration(from text: String) -> Double? {
        guard let range = text.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#,
                                     options: .regularExpression) else { return nil }
        let parts = text[range]
            .dropFirst("Duration: ".count)
            .split(separator: ":")
            .compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// "out_time_us=12345678" lines from -progress → seconds.
    private static func parseOutTime(from text: String) -> Double? {
        for line in text.split(separator: "\n").reversed() {
            if line.hasPrefix("out_time_us="),
               let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                return microseconds / 1_000_000
            }
        }
        return nil
    }
}
