import Foundation

/// A dotted version like "1.2.10". Compares numerically, part by part; missing parts
/// count as 0, so "1.2" == "1.2.0". Non-numeric suffixes ("1.3b1") are ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let numbers = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { piece in Int(piece.prefix { $0.isNumber }) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.compactMap { $0 }
        description = trimmed
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) == 0 }
    public static func < (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) < 0 }

    private static func compare(_ a: AppVersion, _ b: AppVersion) -> Int {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

/// A newer version that was found, from either the App Store or the appcast.
public struct AvailableUpdate: Sendable, Equatable {
    public var version: String
    public var releaseNotes: String?
    /// App Store page (App Store build). Nil for Sparkle, which installs in place.
    public var storeURL: URL?

    public init(version: String, releaseNotes: String? = nil, storeURL: URL? = nil) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.storeURL = storeURL
    }
}

/// When to check, and whether to remind about a found version (UP-1 to UP-4).
/// All state lives in UserDefaults so it survives relaunches.
public struct UpdatePolicy: Sendable, Equatable {
    public static let interval: TimeInterval = 24 * 60 * 60

    public var lastCheck: Date?
    public var skippedVersion: String?
    public var remindAfter: Date?
    /// Versions a system notification was already posted for: one per version (UP-2).
    public var notifiedVersions: [String]

    public init(lastCheck: Date? = nil, skippedVersion: String? = nil, remindAfter: Date? = nil, notifiedVersions: [String] = []) {
        self.lastCheck = lastCheck
        self.skippedVersion = skippedVersion
        self.remindAfter = remindAfter
        self.notifiedVersions = notifiedVersions
    }

    /// UP-1: due when never checked, or the last check was over 24 h ago.
    /// A last check in the future (clock changed) also counts as due.
    public func isCheckDue(now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= Self.interval || elapsed < 0
    }

    /// Whether `found` is newer than `current` and the user hasn't silenced it.
    public func shouldRemind(found: String, current: String, now: Date) -> Bool {
        guard let new = AppVersion(found), let installed = AppVersion(current), new > installed else { return false }
        if let skippedVersion, let skipped = AppVersion(skippedVersion), skipped == new { return false }
        if let remindAfter, now < remindAfter { return false }
        return true
    }

    public func shouldNotify(version: String) -> Bool {
        !notifiedVersions.contains(version)
    }

    public mutating func markNotified(_ version: String) {
        guard shouldNotify(version: version) else { return }
        notifiedVersions.append(version)
        if notifiedVersions.count > 20 { notifiedVersions.removeFirst(notifiedVersions.count - 20) }
    }

    /// Remind Me Tomorrow: quiet until the same time tomorrow.
    public mutating func remindTomorrow(now: Date) {
        remindAfter = now.addingTimeInterval(Self.interval)
    }

    public mutating func skip(_ version: String) {
        skippedVersion = version
        remindAfter = nil
    }

    // MARK: - Storage

    public enum Key {
        public static let checksEnabled = "updates.checksEnabled"
        public static let lastCheck = "updates.lastCheck"
        public static let skippedVersion = "updates.skippedVersion"
        public static let remindAfter = "updates.remindAfter"
        public static let notifiedVersions = "updates.notifiedVersions"
    }

    public init(defaults: UserDefaults) {
        self.init(
            lastCheck: defaults.object(forKey: Key.lastCheck) as? Date,
            skippedVersion: defaults.string(forKey: Key.skippedVersion),
            remindAfter: defaults.object(forKey: Key.remindAfter) as? Date,
            notifiedVersions: defaults.stringArray(forKey: Key.notifiedVersions) ?? []
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(lastCheck, forKey: Key.lastCheck)
        defaults.set(skippedVersion, forKey: Key.skippedVersion)
        defaults.set(remindAfter, forKey: Key.remindAfter)
        defaults.set(notifiedVersions, forKey: Key.notifiedVersions)
    }
}

/// Apple's public lookup API, used by the App Store build only (no download or install:
/// App Store apps must update through the store).
public enum AppStoreLookup {
    public static func url(bundleID: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
        return components?.url
    }

    /// Parses `{"resultCount":1,"results":[{"version":"1.2","releaseNotes":"…","trackViewUrl":"…"}]}`.
    /// Nil when the app isn't listed (resultCount 0) or the JSON is malformed.
    public static func parse(_ data: Data) -> AvailableUpdate? {
        struct Response: Decodable {
            struct Result: Decodable {
                let version: String
                let releaseNotes: String?
                let trackViewUrl: String?
            }
            let results: [Result]
        }
        guard let first = (try? JSONDecoder().decode(Response.self, from: data))?.results.first else { return nil }
        return AvailableUpdate(
            version: first.version,
            releaseNotes: first.releaseNotes,
            storeURL: first.trackViewUrl.flatMap(URL.init(string:))
        )
    }
}

