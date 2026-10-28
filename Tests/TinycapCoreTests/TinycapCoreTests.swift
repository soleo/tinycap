import CoreGraphics
import Foundation
import XCTest
@testable import TinycapCore

final class GeometryTests: XCTestCase {
    func testRectFromPointsIgnoresDragDirection() {
        let r = Geometry.rect(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 20, y: 80))
        XCTAssertEqual(r, CGRect(x: 20, y: 50, width: 80, height: 30))
    }

    func testDisplayLocalRectFlipsYOnPrimaryScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let selection = CGRect(x: 100, y: 700, width: 400, height: 200) // near the top
        XCTAssertEqual(
            Geometry.displayLocalRect(selection, screenFrame: screen),
            CGRect(x: 100, y: 82, width: 400, height: 200)
        )
    }

    func testDisplayLocalRectOnSecondaryScreen() {
        // External display to the right of and above the primary one.
        let screen = CGRect(x: 1512, y: 200, width: 2560, height: 1440)
        let selection = CGRect(x: 1612, y: 1440, width: 100, height: 100)
        XCTAssertEqual(
            Geometry.displayLocalRect(selection, screenFrame: screen),
            CGRect(x: 100, y: 100, width: 100, height: 100)
        )
    }

    func testAppKitRectFromCG() {
        let cg = CGRect(x: 10, y: 0, width: 300, height: 200) // touching the top of the primary screen
        XCTAssertEqual(
            Geometry.appKitRect(fromCG: cg, primaryScreenHeight: 982),
            CGRect(x: 10, y: 782, width: 300, height: 200)
        )
    }

    func testResizeCornerAndFlip() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(
            Geometry.resize(r, edges: [.right, .top], to: CGPoint(x: 400, y: 250)),
            CGRect(x: 100, y: 100, width: 300, height: 150)
        )
        // Dragging the left edge past the right edge flips the rect.
        XCTAssertEqual(
            Geometry.resize(r, edges: .left, to: CGPoint(x: 350, y: 0)),
            CGRect(x: 300, y: 100, width: 50, height: 100)
        )
    }

    func testKeepInside() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            Geometry.keep(CGRect(x: 950, y: -20, width: 100, height: 100), inside: bounds),
            CGRect(x: 900, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(
            Geometry.keep(CGRect(x: 10, y: 10, width: 2000, height: 100), inside: bounds),
            CGRect(x: 0, y: 10, width: 1000, height: 100)
        )
    }

    func testPixelSizeIsEven() {
        let size = Geometry.pixelSize(for: CGSize(width: 641.5, height: 361), scale: 2)
        XCTAssertEqual(size.width, 1282)
        XCTAssertEqual(size.height, 722)
        let odd = Geometry.pixelSize(for: CGSize(width: 641, height: 1), scale: 1)
        XCTAssertEqual(odd.width, 640)
        XCTAssertEqual(odd.height, 2)
    }
}

final class FilenamePatternTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var date: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 20, minute: 45, second: 9))!
    }

    func testDefaultPattern() {
        XCTAssertEqual(FilenamePattern().baseName(for: date, calendar: calendar), "Recording 2026-10-27 at 20.45")
    }

    func testCustomPatternAndSanitizing() {
        let p = FilenamePattern("bug/{date}:{time}.{seconds}")
        XCTAssertEqual(p.baseName(for: date, calendar: calendar), "bug-2026-10-27-20.45.09")
    }

    func testEmptyPatternFallsBackToDefault() {
        XCTAssertEqual(FilenamePattern("  ").pattern, FilenamePattern.defaultPattern)
        XCTAssertEqual(FilenamePattern(".{date}").baseName(for: date, calendar: calendar), "Recording.2026-10-27")
    }

    func testUniqueURLAppendsCounter() {
        let dir = URL(fileURLWithPath: "/tmp/out")
        let taken: Set<String> = ["/tmp/out/Clip.mp4", "/tmp/out/Clip 2.mp4"]
        let url = FilenamePattern.uniqueURL(in: dir, baseName: "Clip", pathExtension: "mp4") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "Clip 3.mp4")
    }
}

final class ElapsedTimeTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(ElapsedTime.format(0), "0:00")
        XCTAssertEqual(ElapsedTime.format(7.9), "0:07")
        XCTAssertEqual(ElapsedTime.format(754), "12:34")
        XCTAssertEqual(ElapsedTime.format(3723), "1:02:03")
        XCTAssertEqual(ElapsedTime.format(-5), "0:00")
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsAndOverrides() {
        let defaults = UserDefaults(suiteName: "TinycapCoreTests-\(UUID().uuidString)")!
        PreferenceKey.registerDefaults(in: defaults)
        XCTAssertEqual(RecordingSettings(defaults: defaults), RecordingSettings())

        defaults.set(60, forKey: PreferenceKey.frameRate)
        defaults.set(false, forKey: PreferenceKey.showsCursor)
        let s = RecordingSettings(defaults: defaults)
        XCTAssertEqual(s.frameRate, .fps60)
        XCTAssertFalse(s.showsCursor)

        defaults.set(42, forKey: PreferenceKey.frameRate)
        XCTAssertEqual(RecordingSettings(defaults: defaults).frameRate, .default)
    }

    func testRecentListDedupesAndCaps() {
        var list = RecentList(limit: 3)
        ["a", "b", "c", "a", "d"].forEach { list.add($0) }
        XCTAssertEqual(list.paths, ["d", "a", "c"])
    }
}

final class WindowRegionTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

    func testWindowOnPrimary() {
        XCTAssertEqual(Geometry.windowSourceRect(window: CGRect(x: 100, y: 50, width: 800, height: 600), display: primary),
                       CGRect(x: 100, y: 50, width: 800, height: 600))
    }

    func testWindowOnExternalDisplayIsMadeLocal() {
        XCTAssertEqual(Geometry.windowSourceRect(window: CGRect(x: 1612, y: -100, width: 800, height: 600), display: external),
                       CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    func testWindowPartlyOffscreenIsShiftedBackKeepingSize() {
        XCTAssertEqual(Geometry.windowSourceRect(window: CGRect(x: -50, y: 700, width: 800, height: 600), display: primary),
                       CGRect(x: 0, y: 382, width: 800, height: 600))
    }

    func testBestDisplayIsTheOneWithMostOfTheWindow() {
        let window = CGRect(x: 1400, y: 100, width: 800, height: 600) // mostly on the external display
        XCTAssertEqual(Geometry.bestDisplayIndex(for: window, displays: [primary, external]), 1)
        XCTAssertEqual(Geometry.bestDisplayIndex(for: CGRect(x: 100, y: 100, width: 10, height: 10), displays: [primary, external]), 0)
        XCTAssertNil(Geometry.bestDisplayIndex(for: window, displays: []))
    }
}
