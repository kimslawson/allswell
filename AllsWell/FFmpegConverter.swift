import AVFoundation
import Foundation

/// Optional backend that shells out to a Homebrew/MacPorts ffmpeg if one is
/// installed. When present, formats macOS can't encode (MP3, OGG, …) simply
/// appear in the picker; when absent, they don't exist and nothing hints
/// otherwise. It also accepts the native backends' formats, so sources AVF
/// can't read (OGG in, say) still convert to M4A or FLAC.
///
/// ffmpeg builds vary: not every install has libvorbis, libx265, and friends.
/// The probe reads `ffmpeg -encoders` once, and a format only exists if this
/// particular binary can actually encode it — otherwise the picker entry
/// would just die with "Encoder not found" at convert time.
final class FFmpegConverter: Converter {
    let engineName = "ffmpeg"

    static let mp3 = OutputFormat(id: "mp3", title: "MP3", fileExtension: "mp3")
    static let ogg = OutputFormat(id: "ogg", title: "OGG", fileExtension: "ogg")
    static let webm = OutputFormat(id: "webm", title: "WebM", fileExtension: "webm")

    private let executableURL: URL
    private let encoders: Set<String>

    var path: String { executableURL.path }

    private init(executableURL: URL, encoders: Set<String>) {
        self.executableURL = executableURL
        self.encoders = encoders
    }

    /// Probes the usual install locations at launch; nil means no usable ffmpeg.
    static func probe() -> FFmpegConverter? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let encoders = availableEncoders(at: url)
            if !encoders.isEmpty {
                return FFmpegConverter(executableURL: url, encoders: encoders)
            }
        }
        return nil
    }

    /// Parses `ffmpeg -encoders`: after the " ------" separator, the second
    /// column of each line is the encoder name.
    private static func availableEncoders(at url: URL) -> Set<String> {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-hide_banner", "-encoders"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var names = Set<String>()
        var pastHeader = false
        for line in text.split(separator: "\n") {
            if !pastHeader {
                pastHeader = line.trimmingCharacters(in: .whitespaces).hasPrefix("------")
                continue
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 {
                names.insert(String(fields[1]))
            }
        }
        return names
    }

    func outputFormats(for mediaClass: MediaClass) -> [OutputFormat] {
        let formats: [OutputFormat]
        switch mediaClass {
        case .audio: formats = [Self.mp3, Self.ogg]
        case .video: formats = [Self.webm, Self.mp3]
        case .image: return []
        }
        return formats.filter { encoderArguments(for: mediaClass, formatID: $0.id) != nil }
    }

    func canConvert(_ media: LoadedMedia, to format: OutputFormat) -> Bool {
        guard case .file = media.payload else { return false }
        return encoderArguments(for: media.mediaClass, formatID: format.id) != nil
    }

    private func has(_ encoder: String) -> Bool {
        encoders.contains(encoder)
    }

    /// Codec arguments per (media class, format), nil when this build lacks
    /// the encoder. Includes the native backends' formats so ffmpeg can be
    /// the fallback reader for them (MKV in, MP4 out; OGG in, FLAC out).
    /// Audio outputs take `-vn`: embedded cover art is a video stream, and
    /// muxers like OGG would otherwise demand a video encoder for it.
    private func encoderArguments(for mediaClass: MediaClass, formatID: String) -> [String]? {
        switch (mediaClass, formatID) {
        case (.audio, "mp3"), (.video, "mp3"):
            guard has("libmp3lame") else { return nil }
            return ["-vn", "-codec:a", "libmp3lame", "-q:a", "1"]
        case (.audio, "ogg"):
            if has("libvorbis") {
                return ["-vn", "-codec:a", "libvorbis", "-q:a", "6"]
            }
            if has("libopus") {
                return ["-vn", "-codec:a", "libopus", "-b:a", "160k"]
            }
            return nil
        case (.audio, "m4a"), (.video, "m4a"):
            guard has("aac") else { return nil }
            return ["-vn", "-codec:a", "aac", "-b:a", "256k"]
        case (.audio, "wav"):
            guard has("pcm_s16le") else { return nil }
            return ["-vn", "-codec:a", "pcm_s16le"]
        case (.audio, "flac"):
            guard has("flac") else { return nil }
            return ["-vn", "-codec:a", "flac"]
        case (.audio, "alac"):
            guard has("alac") else { return nil }
            return ["-vn", "-codec:a", "alac"]
        case (.video, "mp4-h264"):
            guard has("libx264"), has("aac") else { return nil }
            return ["-codec:v", "libx264", "-preset", "veryfast", "-crf", "20",
                    "-codec:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case (.video, "mp4-hevc"):
            guard has("libx265"), has("aac") else { return nil }
            return ["-codec:v", "libx265", "-preset", "fast", "-crf", "23",
                    "-tag:v", "hvc1", "-codec:a", "aac", "-b:a", "192k"]
        case (.video, "mov-prores"):
            guard has("prores_ks"), has("pcm_s16le") else { return nil }
            return ["-codec:v", "prores_ks", "-profile:v", "2",
                    "-codec:a", "pcm_s16le"]
        case (.video, "webm"):
            guard has("libvpx-vp9") else { return nil }
            let audio: [String]
            if has("libopus") {
                audio = ["-codec:a", "libopus"]
            } else if has("libvorbis") {
                audio = ["-codec:a", "libvorbis"]
            } else {
                return nil
            }
            return ["-codec:v", "libvpx-vp9", "-crf", "32", "-b:v", "0",
                    "-row-mt", "1"] + audio
        default:
            return nil
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
              let codecArguments = encoderArguments(for: media.mediaClass, formatID: format.id)
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
            guard let process, process.isRunning else { return }
            process.terminate()
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
