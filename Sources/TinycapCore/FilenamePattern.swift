import Foundation

/// What a file is being named for: the values behind the pattern's tokens.
public struct FilenameContext: Sendable, Equatable {
    public enum Kind: String, Sendable { case recording, screenshot }

    public var kind: Kind
    public var date: Date
    /// The captured app, or the frontmost app for screen and area captures.
    public var app: String?
    /// The captured window's title; nil for screen and area captures.
    public var window: String?
    /// The value of `{n}`.
    public var counter: Int

    public init(kind: Kind, date: Date = Date(), app: String? = nil, window: String? = nil, counter: Int = 1) {
        self.kind = kind
        self.date = date
        self.app = app
        self.window = window
        self.counter = counter
    }

    public var typeName: String { kind == .recording ? "Recording" : "Screenshot" }
}

/// Builds output file names such as "Recording 2026-10-27 at 20.45.mp4" (EX-8, EX-12).
public struct FilenamePattern: Sendable, Equatable {
    public struct Token: Sendable, Identifiable {
        public let text: String
        public let help: String
        public var id: String { text }
    }

    /// Tokens offered in Settings, in the order shown.
    public static let tokens: [Token] = [
        Token(text: "{type}", help: "Recording or Screenshot"),
        Token(text: "{date}", help: "Date, as 2026-10-27"),
        Token(text: "{time}", help: "Time, as 20.45"),
        Token(text: "{seconds}", help: "Seconds, as 09"),
        Token(text: "{app}", help: "The captured app, or the frontmost app for screen and area captures"),
        Token(text: "{window}", help: "The captured window's title; empty for screen and area captures"),
        Token(text: "{n}", help: "A counter that goes up by one with each file saved"),
    ]

    public static let defaultPattern = "{type} {date} at {time}"
    /// The default before `{type}` existed. Treated as the default, so screenshots saved
    /// with it are still named "Screenshot …".
    static let legacyDefaultPattern = "Recording {date} at {time}"

    /// Longest base name, in characters (EX-11).
    public static let maxLength = 200

    public let pattern: String

    public init(_ pattern: String = FilenamePattern.defaultPattern) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pattern = trimmed.isEmpty || trimmed == Self.legacyDefaultPattern ? Self.defaultPattern : trimmed
    }

    public var usesCounter: Bool { pattern.contains("{n}") }

    /// File name without extension.
    public func baseName(for context: FilenameContext, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: context.date)
        func pad(_ v: Int?, _ width: Int = 2) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        // Token values can hold "/" or ":" (a window titled "a/b"); those become "-"
        // like the pattern's own text does.
        let values: [(String, String)] = [
            ("{type}", context.typeName),
            ("{date}", "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day))"),
            ("{time}", "\(pad(c.hour)).\(pad(c.minute))"),
            ("{seconds}", pad(c.second)),
            ("{app}", context.app ?? ""),
            ("{window}", context.window ?? ""),
            ("{n}", String(context.counter)),
        ]
        var name = pattern
        for (token, value) in values {
            name = name.replacingOccurrences(of: token, with: value)
        }
        // An empty {app} or {window} leaves doubled spaces or a dangling separator.
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_·"))
        let replaced = String(name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return Self.clean(replaced) ?? context.typeName
    }

    /// Makes a typed name safe to save (EX-11): drops "/", ":" and control characters,
    /// leading dots and surrounding spaces, a trailing ".<ext>" the user typed, and trims
    /// to `maxLength` characters (and 240 UTF-8 bytes, leaving room for " 2.webm" under
    /// the file system's 255). Returns nil when nothing usable is left.
    public static func clean(_ name: String, pathExtension: String? = nil) -> String? {
        var s = String(name.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0)
        }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespaces)
        if let ext = pathExtension, !ext.isEmpty, s.lowercased().hasSuffix("." + ext.lowercased()) {
            s = String(s.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength { s = String(s.prefix(maxLength)) }
        while s.utf8.count > 240 { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
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
}
