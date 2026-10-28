import CoreGraphics
import Foundation
import XCTest
@testable import TinycapCore

final class ExportSettingsTests: XCTestCase {
    func testOutputSizeScales() {
        let source = CGSize(width: 2560, height: 1600)
        XCTAssertTrue(ExportSettings(scale: .full).outputSize(for: source) == (2560, 1600))
        XCTAssertTrue(ExportSettings(scale: .half).outputSize(for: source) == (1280, 800))
        XCTAssertTrue(ExportSettings(scale: .width(1280)).outputSize(for: source) == (1280, 800))
        // Fixed width never upscales.
        XCTAssertTrue(ExportSettings(scale: .width(4000)).outputSize(for: source) == (2560, 1600))
        // Odd results round down to even.
        XCTAssertTrue(ExportSettings(scale: .width(1001)).outputSize(for: CGSize(width: 1920, height: 1080)) == (1000, 562))
    }

    func testScaleStorageRoundTrip() {
        for scale in [OutputScale.full, .half, .width(1280)] {
            XCTAssertEqual(OutputScale(storageValue: scale.storageValue), scale)
        }
        XCTAssertEqual(OutputScale(storageValue: "w0"), .full)
        XCTAssertEqual(OutputScale(storageValue: "garbage"), .full)
    }

    func testQualityIsClampedAndMonotonic() {
        XCTAssertEqual(ExportSettings(quality: 3).quality, 1)
        XCTAssertEqual(ExportSettings(quality: -1).quality, 0)
        let low = ExportSettings(quality: 0.2).bitrate(width: 1280, height: 800, frameRate: 30)
        let high = ExportSettings(quality: 0.8).bitrate(width: 1280, height: 800, frameRate: 30)
        XCTAssertLessThan(low, high)
        let hevc = ExportSettings(codec: .hevc, quality: 0.8).bitrate(width: 1280, height: 800, frameRate: 30)
        XCTAssertLessThan(hevc, high)
    }

    /// PRD metric: a 30 s, 1280 px-wide UI clip as MP4 is under 5 MB at default quality.
    func testDefaultMeetsFiveMegabyteTarget() {
        let bytes = ExportSettings().estimatedBytes(sourceSize: CGSize(width: 1280, height: 800), frameRate: 30, duration: 30)
        XCTAssertLessThan(bytes, 5_000_000)
        XCTAssertGreaterThan(bytes, 2_000_000)
    }

    func testDefaultsFromUserDefaults() {
        let defaults = UserDefaults(suiteName: "ExportSettingsTests-\(UUID().uuidString)")!
        PreferenceKey.registerDefaults(in: defaults)
        XCTAssertEqual(ExportSettings(defaults: defaults), ExportSettings())
        defaults.set("hevc", forKey: PreferenceKey.exportCodec)
        defaults.set(0.9, forKey: PreferenceKey.exportQuality)
        defaults.set("w1280", forKey: PreferenceKey.exportScale)
        XCTAssertEqual(ExportSettings(defaults: defaults), ExportSettings(codec: .hevc, quality: 0.9, scale: .width(1280)))
    }

    func testByteSizeFormatting() {
        XCTAssertEqual(ByteSize.format(840_000), "840 KB")
        XCTAssertEqual(ByteSize.format(200), "1 KB")
        XCTAssertEqual(ByteSize.format(4_230_000), "4.2 MB")
        XCTAssertEqual(ByteSize.format(1_300_000_000), "1.30 GB")
    }
}

final class TrimRangeTests: XCTestCase {
    func testStartAndEndStayOrderedWithMinimumGap() {
        var trim = TrimRange(duration: 10)
        XCTAssertFalse(trim.isTrimmed)
        trim.setStart(2)
        trim.setEnd(8)
        XCTAssertEqual(trim.length, 6)
        XCTAssertTrue(trim.isTrimmed)

        trim.setStart(9) // past the end
        XCTAssertEqual(trim.start, 8 - TrimRange.minimumLength, accuracy: 1e-9)
        trim.setEnd(1) // before the start
        XCTAssertEqual(trim.end, trim.start + TrimRange.minimumLength, accuracy: 1e-9)

        trim.setStart(-5)
        trim.setEnd(99)
        XCTAssertEqual(trim.start, 0)
        XCTAssertEqual(trim.end, 10)
    }

    func testPlayheadClamp() {
        var trim = TrimRange(duration: 10)
        trim.setStart(2)
        trim.setEnd(5)
        XCTAssertEqual(trim.clampedPlayhead(1), 2)
        XCTAssertEqual(trim.clampedPlayhead(3), 3)
        XCTAssertEqual(trim.clampedPlayhead(7), 5)
    }

    func testZeroDuration() {
        var trim = TrimRange(duration: 0)
        trim.setStart(1)
        trim.setEnd(1)
        XCTAssertEqual(trim.start, 0)
        XCTAssertEqual(trim.end, 0)
    }
}

final class KeyComboTests: XCTestCase {
    func testDisplayAndValidity() {
        let combo = KeyCombo(keyCode: 0x00, modifiers: [.command, .shift, .control], keyName: "A")
        XCTAssertEqual(combo.displayString, "⌃⇧⌘A")
        XCTAssertTrue(combo.isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: 0x00, modifiers: [.shift], keyName: "A").isValidGlobalShortcut)
        XCTAssertTrue(KeyCombo(keyCode: 0x60, modifiers: [], keyName: "F5").isValidGlobalShortcut)
    }

    func testStoreDefaultsClearAndConflicts() {
        let defaults = UserDefaults(suiteName: "KeyComboTests-\(UUID().uuidString)")!
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.combo(for: .stop), ShortcutAction.stop.defaultCombo)

        let custom = KeyCombo(keyCode: 0x0F, modifiers: [.option, .command], keyName: "R")
        store.set(custom, for: .recordArea)
        XCTAssertEqual(store.combo(for: .recordArea), custom)
        XCTAssertEqual(store.conflict(for: custom, excluding: .recordWindow), .recordArea)
        XCTAssertNil(store.conflict(for: custom, excluding: .recordArea))

        store.set(nil, for: .recordScreen)
        XCTAssertNil(store.combo(for: .recordScreen))

        store.resetAll()
        XCTAssertEqual(store.combo(for: .recordArea), ShortcutAction.recordArea.defaultCombo)
        XCTAssertEqual(store.combo(for: .recordScreen), ShortcutAction.recordScreen.defaultCombo)
    }
}
