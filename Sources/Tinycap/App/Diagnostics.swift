import AppKit
import TinycapCore

/// Version facts for bug reports, the last error shown to the user, and the
/// Report a Bug… / Send Feedback… actions (FB-1 to FB-5).
@MainActor
enum Diagnostics {
    /// From `TinycapRepositoryURL` in Info.plist, so forks point at their own issues.
    static var repositoryURL: URL? { plistURL("TinycapRepositoryURL") }
    static var authorURL: URL? { plistURL("TinycapAuthorURL") }
    static var authorGitHubURL: URL? { plistURL("TinycapAuthorGitHubURL") }

    private static func plistURL(_ key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap(URL.init(string:))
    }

    static var commitURL: URL? {
        guard let repo = repositoryURL, let commit = current.commit else { return nil }
        return BuildStamp.commitURL(repository: repo, commit: commit)
    }

    static var releaseNotesURL: URL? {
        repositoryURL.map { BuildStamp.releaseNotesURL(repository: $0, version: current.appVersion) }
    }

    static var current: DiagnosticInfo {
        let bundle = Bundle.main
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOS: Feedback.macOSVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion),
            chip: Feedback.chipName(fromBrand: cpuBrand()),
            channel: channel,
            commit: BuildStamp.commit(bundle.object(forInfoDictionaryKey: "TCGitCommit") as? String),
            buildDate: BuildStamp.date(bundle.object(forInfoDictionaryKey: "TCBuildDate") as? String)
        )
    }

    /// Mac App Store copies carry a receipt at Contents/_MASReceipt; direct downloads don't.
    /// Checked as a file so the answer is immediate and needs no network.
    static var channel: DistributionChannel {
        let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path) ? .appStore : .direct
    }

    private static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Last error

    /// Remembers an error the user just saw, for Copy Diagnostics. Stays on this Mac.
    static func record(_ error: Error, context: String) {
        UserDefaults.standard.set("\(context): \(error.localizedDescription)", forKey: PreferenceKey.lastError)
    }

    static var lastError: String? {
        UserDefaults.standard.string(forKey: PreferenceKey.lastError)
    }

    // MARK: - Actions

    static func open(_ kind: Feedback.Kind) {
        guard let repo = repositoryURL, let url = Feedback.issueURL(repository: repo, kind: kind, info: current) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openIssues() {
        guard let repo = repositoryURL else { return }
        NSWorkspace.shared.open(Feedback.issuesURL(repository: repo))
    }

    static func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Feedback.diagnosticsText(current, lastError: lastError), forType: .string)
    }
}
