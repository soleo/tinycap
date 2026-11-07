import CoreGraphics
import XCTest
@testable import TinycapCore

final class AppPreviewTests: XCTestCase {
    func testDeviceKindFromScreenShape() {
        XCTAssertEqual(DeviceKind(pixelSize: CGSize(width: 1179, height: 2556)), .iPhone)     // iPhone 15
        XCTAssertEqual(DeviceKind(pixelSize: CGSize(width: 2556, height: 1179)), .iPhone)     // landscape
        XCTAssertEqual(DeviceKind(pixelSize: CGSize(width: 750, height: 1334)), .homeButtonIPhone) // iPhone SE
        XCTAssertEqual(DeviceKind(pixelSize: CGSize(width: 1640, height: 2360)), .iPad)       // iPad Air
        XCTAssertEqual(DeviceKind(pixelSize: CGSize(width: 2048, height: 2732)), .iPad)       // iPad Pro 12.9"
        XCTAssertEqual(DeviceKind(pixelSize: CGSize(width: 1488, height: 2266)), .iPad)       // iPad mini
    }

    func testPointScale() {
        XCTAssertEqual(DeviceKind.pointScale(for: CGSize(width: 1179, height: 2556)), 3)
        XCTAssertEqual(DeviceKind.pointScale(for: CGSize(width: 750, height: 1334)), 2)
        XCTAssertEqual(DeviceKind.pointScale(for: CGSize(width: 1080, height: 1920)), 3)
        XCTAssertEqual(DeviceKind.pointScale(for: CGSize(width: 1640, height: 2360)), 2)
    }

    func testAcceptedSizes() {
        XCTAssertTrue(AppPreview.size(for: CGSize(width: 1179, height: 2556)) == (886, 1920))
        XCTAssertTrue(AppPreview.size(for: CGSize(width: 2556, height: 1179)) == (1920, 886))
        XCTAssertTrue(AppPreview.size(for: CGSize(width: 750, height: 1334)) == (1080, 1920))
        XCTAssertTrue(AppPreview.size(for: CGSize(width: 1640, height: 2360)) == (1200, 1600))
        XCTAssertTrue(AppPreview.size(for: CGSize(width: 2360, height: 1640)) == (1600, 1200))
    }

    func testDurationRules() {
        XCTAssertNotNil(AppPreview.durationProblem(14.5))
        XCTAssertNil(AppPreview.durationProblem(15))
        XCTAssertNil(AppPreview.durationProblem(14.99))
        XCTAssertNil(AppPreview.durationProblem(30))
        XCTAssertNotNil(AppPreview.durationProblem(31))
    }

    func testExportSettingsUsePresetSizeAndBitrate() {
        let settings = ExportSettings(codec: .hevc, quality: 0, scale: .half, appPreview: true)
        XCTAssertTrue(settings.outputSize(for: CGSize(width: 1179, height: 2556)) == (886, 1920))
        XCTAssertEqual(settings.bitrate(width: 886, height: 1920, frameRate: 60), AppPreview.videoBitrate)
        // 11 Mbps for 20 s, about 27.5 MB plus overhead.
        let bytes = settings.estimatedBytes(sourceSize: CGSize(width: 1179, height: 2556), frameRate: 60, duration: 20)
        XCTAssertEqual(Double(bytes), 27_500_000 * 1.01, accuracy: 10_000)
    }

    func testDeviceAudioSource() {
        XCTAssertEqual(AudioSource(trackName: "Device Audio"), .device)
        XCTAssertEqual(AudioSource.device.channelCount, 2)
        XCTAssertEqual(AudioSource.microphone.channelCount, 1)
    }
}
