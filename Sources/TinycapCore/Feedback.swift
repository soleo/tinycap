import Foundation

/// How this copy of Tinycap was installed. Bug reports carry it (FB-2).
public enum DistributionChannel: String, Sendable, CaseIterable {
    case appStore = "appstore"
    case direct
}

/// Version facts prefilled into bug reports and copied by Copy Diagnostics.
public struct DiagnosticInfo: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var macOS: String
    public var chip: String
    public var channel: DistributionChannel

    public init(appVersion: String, build: String, macOS: String, chip: String, channel: DistributionChannel) {
        self.appVersion = appVersion
        self.build = build
        self.macOS = macOS
        self.chip = chip
        self.channel = channel
    }
}

/// Builds the GitHub issue-form links behind Report a Bug… and Send Feedback… (FB-1, FB-2).
/// Nothing is sent by the app: the link opens in the browser and the user submits it (FB-3).
public enum Feedback {
    public enum Kind: Sendable, CaseIterable {
        case bug, feature

        /// File name under `.github/ISSUE_TEMPLATE/` in the repo.
        public var template: String {
            switch self {
            case .bug: return "bug_report.yml"
            case .feature: return "feature_request.yml"
            }
        }
    }

    /// Issue-form query keys. They must match the field `id`s in the repo's issue forms.
    public enum Field {
        public static let appVersion = "app-version"
        public static let build = "build"
        public static let macOS = "macos"
        public static let chip = "chip"
        public static let channel = "channel"
    }

    /// `https://github.com/<org>/tinycap/issues/new?template=…&app-version=…`.
    /// Returns nil if `repository` isn't an http(s) URL.
    public static func issueURL(repository: URL, kind: Kind, info: DiagnosticInfo) -> URL? {
        guard let scheme = repository.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let base = repository.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/issues/new") else { return nil }

        var items = [URLQueryItem(name: "template", value: kind.template)]
        switch kind {
        case .bug:
            items += [
                URLQueryItem(name: Field.appVersion, value: info.appVersion),
                URLQueryItem(name: Field.build, value: info.build),
                URLQueryItem(name: Field.macOS, value: info.macOS),
                URLQueryItem(name: Field.chip, value: info.chip),
                URLQueryItem(name: Field.channel, value: info.channel.rawValue),
            ]
        case .feature:
            items.append(URLQueryItem(name: Field.appVersion, value: info.appVersion))
        }
        components.queryItems = items
        return components.url
    }

    /// The GitHub issues page, also the App Store support URL (FB-4).
    public static func issuesURL(repository: URL) -> URL {
        repository.appendingPathComponent("issues")
    }

    /// "Apple M2 Pro" → "M2 Pro"; any Intel brand string → "Intel". Unknown text is kept.
    public static func chipName(fromBrand brand: String) -> String {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unknown" }
        if trimmed.localizedCaseInsensitiveContains("intel") { return "Intel" }
        if trimmed.hasPrefix("Apple ") { return String(trimmed.dropFirst("Apple ".count)) }
        return trimmed
    }

    /// "15.1" for 15.1.0, "15.1.1" when there is a patch number.
    public static func macOSVersion(major: Int, minor: Int, patch: Int) -> String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Plain text for Copy Diagnostics (FB-5), meant to be pasted into an issue.
    public static func diagnosticsText(_ info: DiagnosticInfo, lastError: String?) -> String {
        var lines = [
            "Tinycap \(info.appVersion) (\(info.build))",
            "Channel: \(info.channel == .appStore ? "App Store" : "Direct")",
            "macOS \(info.macOS)",
            "Chip: \(info.chip)",
        ]
        if let lastError, !lastError.isEmpty {
            lines.append("Last error: \(lastError)")
        } else {
            lines.append("Last error: none")
        }
        return lines.joined(separator: "\n")
    }
}
