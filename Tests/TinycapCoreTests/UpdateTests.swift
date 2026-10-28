import Foundation
import XCTest
@testable import TinycapCore

final class AppVersionTests: XCTestCase {
    func testNumericOrdering() {
        XCTAssertLessThan(AppVersion("1.2.9")!, AppVersion("1.2.10")!)
        XCTAssertLessThan(AppVersion("0.9")!, AppVersion("1.0")!)
        XCTAssertGreaterThan(AppVersion("2.0")!, AppVersion("1.99.99")!)
    }

    func testMissingPartsAreZero() {
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertFalse(AppVersion("1.2")! < AppVersion("1.2.0")!)
    }

    func testSuffixesIgnoredAndJunkRejected() {
        XCTAssertEqual(AppVersion("1.3b1")!, AppVersion("1.3")!)
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion("1..2"))
    }
}

final class UpdatePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCheckDue() {
        XCTAssertTrue(UpdatePolicy().isCheckDue(now: now))
        XCTAssertFalse(UpdatePolicy(lastCheck: now.addingTimeInterval(-3600)).isCheckDue(now: now))
        XCTAssertTrue(UpdatePolicy(lastCheck: now.addingTimeInterval(-UpdatePolicy.interval)).isCheckDue(now: now))
        XCTAssertTrue(UpdatePolicy(lastCheck: now.addingTimeInterval(3600)).isCheckDue(now: now), "clock moved back")
    }

    func testRemindsOnlyForNewerVersions() {
        let policy = UpdatePolicy()
        XCTAssertTrue(policy.shouldRemind(found: "0.2.0", current: "0.1.0", now: now))
        XCTAssertFalse(policy.shouldRemind(found: "0.1.0", current: "0.1.0", now: now))
        XCTAssertFalse(policy.shouldRemind(found: "0.0.9", current: "0.1.0", now: now))
        XCTAssertFalse(policy.shouldRemind(found: "junk", current: "0.1.0", now: now))
    }

    func testSkipSilencesOnlyThatVersion() {
        var policy = UpdatePolicy()
        policy.skip("0.2.0")
        XCTAssertFalse(policy.shouldRemind(found: "0.2.0", current: "0.1.0", now: now))
        XCTAssertTrue(policy.shouldRemind(found: "0.2.1", current: "0.1.0", now: now))
    }

    func testRemindTomorrow() {
        var policy = UpdatePolicy()
        policy.remindTomorrow(now: now)
        XCTAssertFalse(policy.shouldRemind(found: "0.2.0", current: "0.1.0", now: now.addingTimeInterval(3600)))
        XCTAssertTrue(policy.shouldRemind(found: "0.2.0", current: "0.1.0", now: now.addingTimeInterval(UpdatePolicy.interval + 1)))
    }

    func testOneNotificationPerVersion() {
        var policy = UpdatePolicy()
        XCTAssertTrue(policy.shouldNotify(version: "0.2.0"))
        policy.markNotified("0.2.0")
        policy.markNotified("0.2.0")
        XCTAssertFalse(policy.shouldNotify(version: "0.2.0"))
        XCTAssertTrue(policy.shouldNotify(version: "0.3.0"))
        XCTAssertEqual(policy.notifiedVersions, ["0.2.0"])
    }

    func testRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "tinycap.tests.updates")!
        defaults.removePersistentDomain(forName: "tinycap.tests.updates")
        var policy = UpdatePolicy(lastCheck: now, skippedVersion: "0.2.0")
        policy.remindTomorrow(now: now)
        policy.markNotified("0.3.0")
        policy.save(to: defaults)
        XCTAssertEqual(UpdatePolicy(defaults: defaults), policy)
    }
}

final class AppStoreLookupTests: XCTestCase {
    func testURL() {
        XCTAssertEqual(AppStoreLookup.url(bundleID: "app.tinycap.Tinycap")?.absoluteString,
                       "https://itunes.apple.com/lookup?bundleId=app.tinycap.Tinycap")
    }

    func testParsesFirstResult() {
        let json = #"{"resultCount":1,"results":[{"version":"1.2.0","releaseNotes":"Faster GIFs","trackViewUrl":"https://apps.apple.com/app/id123","bundleId":"app.tinycap.Tinycap"}]}"#
        XCTAssertEqual(AppStoreLookup.parse(Data(json.utf8)), AvailableUpdate(
            version: "1.2.0", releaseNotes: "Faster GIFs", storeURL: URL(string: "https://apps.apple.com/app/id123")))
    }

    func testNotListedOrMalformed() {
        XCTAssertNil(AppStoreLookup.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8)))
        XCTAssertNil(AppStoreLookup.parse(Data("not json".utf8)))
    }
}

