import Foundation
import XCTest
@testable import TinycapCore

final class FeedbackTests: XCTestCase {
    private let repo = URL(string: "https://github.com/soleo/tinycap")!
    private let info = DiagnosticInfo(appVersion: "0.2.0", build: "7", macOS: "15.1", chip: "M2 Pro", channel: .direct)

    private func query(_ url: URL?) -> [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testBugURLCarriesAllPrefillFields() {
        let url = Feedback.issueURL(repository: repo, kind: .bug, info: info)
        XCTAssertEqual(url?.path, "/soleo/tinycap/issues/new")
        XCTAssertEqual(query(url), [
            "template": "bug_report.yml",
            "app-version": "0.2.0",
            "build": "7",
            "macos": "15.1",
            "chip": "M2 Pro",
            "channel": "direct",
        ])
        XCTAssertTrue(url!.absoluteString.contains("chip=M2%20Pro"))
    }

    func testFeatureURLCarriesOnlyVersion() {
        let url = Feedback.issueURL(repository: repo, kind: .feature, info: info)
        XCTAssertEqual(query(url), ["template": "feature_request.yml", "app-version": "0.2.0"])
    }

    func testTrailingSlashInRepositoryIsIgnored() {
        let url = Feedback.issueURL(repository: URL(string: "https://github.com/soleo/tinycap/")!, kind: .bug, info: info)
        XCTAssertEqual(url?.path, "/soleo/tinycap/issues/new")
    }

    func testNonWebRepositoryIsRejected() {
        XCTAssertNil(Feedback.issueURL(repository: URL(fileURLWithPath: "/tmp/repo"), kind: .bug, info: info))
    }

    func testAppStoreChannelValue() {
        var store = info
        store.channel = .appStore
        XCTAssertEqual(query(Feedback.issueURL(repository: repo, kind: .bug, info: store))["channel"], "appstore")
    }

    func testIssuesURL() {
        XCTAssertEqual(Feedback.issuesURL(repository: repo).absoluteString, "https://github.com/soleo/tinycap/issues")
    }

    func testChipName() {
        XCTAssertEqual(Feedback.chipName(fromBrand: "Apple M2 Pro"), "M2 Pro")
        XCTAssertEqual(Feedback.chipName(fromBrand: "Apple M4"), "M4")
        XCTAssertEqual(Feedback.chipName(fromBrand: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"), "Intel")
        XCTAssertEqual(Feedback.chipName(fromBrand: "  "), "Unknown")
        XCTAssertEqual(Feedback.chipName(fromBrand: "VirtualApple"), "VirtualApple")
    }

    func testMacOSVersion() {
        XCTAssertEqual(Feedback.macOSVersion(major: 15, minor: 1, patch: 0), "15.1")
        XCTAssertEqual(Feedback.macOSVersion(major: 26, minor: 0, patch: 1), "26.0.1")
    }

    func testDiagnosticsText() {
        XCTAssertEqual(Feedback.diagnosticsText(info, lastError: nil), """
            Tinycap 0.2.0 (7)
            Commit: unknown
            Built: unknown
            Channel: Direct
            macOS 15.1
            Chip: M2 Pro
            Last error: none
            """)
        XCTAssertTrue(Feedback.diagnosticsText(info, lastError: "Disk full").hasSuffix("Last error: Disk full"))
    }
}

final class BuildStampTests: XCTestCase {
    private let repo = URL(string: "https://github.com/soleo/tinycap")!

    func testDateParsesISO8601AndIgnoresPlaceholder() {
        XCTAssertEqual(BuildStamp.date("2026-10-28T17:30:00Z"), Date(timeIntervalSince1970: 1_793_208_600))
        XCTAssertNil(BuildStamp.date("$(BUILD_DATE)"))
        XCTAssertNil(BuildStamp.date(nil))
    }

    func testCommitIgnoresPlaceholders() {
        XCTAssertEqual(BuildStamp.commit("7a4e883"), "7a4e883")
        XCTAssertNil(BuildStamp.commit("$(GIT_COMMIT)"))
        XCTAssertNil(BuildStamp.commit("unknown"))
        XCTAssertNil(BuildStamp.commit(""))
    }

    func testCommitURL() {
        XCTAssertEqual(BuildStamp.commitURL(repository: repo, commit: "7a4e883")?.absoluteString,
                       "https://github.com/soleo/tinycap/commit/7a4e883")
        XCTAssertNil(BuildStamp.commitURL(repository: repo, commit: "7a4e883-dirty"))
        XCTAssertNil(BuildStamp.commitURL(repository: repo, commit: "main"))
    }

    func testReleaseNotesURL() {
        XCTAssertEqual(BuildStamp.releaseNotesURL(repository: repo, version: "0.1.0").absoluteString,
                       "https://github.com/soleo/tinycap/releases/tag/v0.1.0")
    }

    func testDiagnosticsIncludeCommitAndDate() {
        let info = DiagnosticInfo(appVersion: "0.2.0", build: "7", macOS: "15.1", chip: "M2", channel: .direct,
                                  commit: "7a4e883", buildDate: Date(timeIntervalSince1970: 1_793_208_600))
        let text = Feedback.diagnosticsText(info, lastError: nil)
        XCTAssertTrue(text.contains("Commit: 7a4e883"))
        XCTAssertTrue(text.contains("Built: 2026-10-28T17:30:00Z"))
    }
}

final class RecordingSettingsM5Tests: XCTestCase {
    func testCountdownAndClickHighlightDefaultOff() {
        let defaults = UserDefaults(suiteName: "tinycap.tests.m5")!
        defaults.removePersistentDomain(forName: "tinycap.tests.m5")
        let settings = RecordingSettings(defaults: defaults)
        XCTAssertFalse(settings.highlightsClicks)
        XCTAssertFalse(settings.countdown)

        defaults.set(true, forKey: PreferenceKey.highlightsClicks)
        defaults.set(true, forKey: PreferenceKey.countdown)
        let on = RecordingSettings(defaults: defaults)
        XCTAssertTrue(on.highlightsClicks)
        XCTAssertTrue(on.countdown)
    }
}
