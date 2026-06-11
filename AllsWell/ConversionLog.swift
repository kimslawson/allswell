import Foundation

/// In-memory session log of what the conversion queue did and why. Batches
/// never throw dialogs — failures land here instead. Main thread only.
final class ConversionLog {
    static let shared = ConversionLog()
    static let didChange = Notification.Name("ConversionLogDidChange")

    struct Entry {
        enum Level {
            case info
            case error
        }

        let date: Date
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []

    func info(_ message: String) {
        append(.info, message)
    }

    func error(_ message: String) {
        append(.error, message)
    }

    func clear() {
        entries.removeAll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func append(_ level: Entry.Level, _ message: String) {
        entries.append(Entry(date: Date(), level: level, message: message))
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
