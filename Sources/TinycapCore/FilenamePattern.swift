import Foundation

/// Builds output file names such as "Recording 2026-10-27 at 20.45.mp4".
///
/// Supported tokens: `{date}` (yyyy-MM-dd), `{time}` (HH.mm), `{seconds}` (ss).
public struct FilenamePattern: Sendable, Equatable {
    public static let defaultPattern = "Recording {date} at {time}"
    public static let defaultScreenshotPattern = "Screenshot {date} at {time}"

    /// Screenshots use "Screenshot …" while the pattern is the default; a custom pattern
    /// applies to both.
    public var forScreenshots: FilenamePattern {
        pattern == Self.defaultPattern ? FilenamePattern(Self.defaultScreenshotPattern) : self
    }

    public let pattern: String

    public init(_ pattern: String = FilenamePattern.defaultPattern) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pattern = trimmed.isEmpty ? FilenamePattern.defaultPattern : trimmed
    }

    /// File name without extension for a recording made at `date`.
    public func baseName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int = 2) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let date = "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day))"
        let time = "\(pad(c.hour)).\(pad(c.minute))"
        let name = pattern
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{seconds}", with: pad(c.second))
        return Self.sanitize(name)
    }

    /// Returns `directory/<baseName>.<ext>`, appending " 2", " 3"… if a file already exists.
    public static func uniqueURL(
        in directory: URL,
        baseName: String,
        pathExtension: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var n = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(pathExtension)
            n += 1
        }
        return candidate
    }

    /// Replaces characters that Finder or the file system reject in names.
    static func sanitize(_ name: String) -> String {
        let cleaned = name.map { ch -> Character in
            ch == "/" || ch == ":" || ch.isNewline ? "-" : ch
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty || result.hasPrefix(".") ? "Recording" + result : result
    }
}
