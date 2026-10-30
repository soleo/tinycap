import Foundation
import XCTest
@testable import TinycapCore

final class AudioSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AudioSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        PreferenceKey.registerDefaults(in: d)
        return d
    }

    func testAudioIsOffByDefault() {
        let s = RecordingSettings(defaults: defaults())
        XCTAssertFalse(s.recordsSystemAudio)
        XCTAssertFalse(s.recordsMicrophone)
        XCTAssertNil(s.microphoneID)
        XCTAssertEqual(s.audioSources, [])
    }

    func testMP4MixesSoundByDefault() {
        // Browsers play only an MP4's first sound track, so one mixed track is the default.
        XCTAssertFalse(defaults().bool(forKey: PreferenceKey.separateAudioTracks))
    }

    func testReadsAudioSettings() {
        let d = defaults()
        d.set(true, forKey: PreferenceKey.recordsSystemAudio)
        d.set(true, forKey: PreferenceKey.recordsMicrophone)
        d.set("BuiltInMicrophoneDevice", forKey: PreferenceKey.microphoneID)
        let s = RecordingSettings(defaults: d)
        XCTAssertEqual(s.audioSources, [.system, .microphone])
        XCTAssertEqual(s.microphoneID, "BuiltInMicrophoneDevice")
    }

    func testEmptyMicrophoneIDMeansSystemInput() {
        let d = defaults()
        d.set("", forKey: PreferenceKey.microphoneID)
        XCTAssertNil(RecordingSettings(defaults: d).microphoneID)
    }

    func testTrackOrderIsSystemThenMicrophone() {
        XCTAssertEqual(RecordingSettings(recordsSystemAudio: false, recordsMicrophone: true).audioSources, [.microphone])
        XCTAssertEqual(RecordingSettings(recordsSystemAudio: true, recordsMicrophone: false).audioSources, [.system])
    }

    func testTrackNamesRoundTrip() {
        for source in AudioSource.allCases {
            XCTAssertEqual(AudioSource(trackName: source.trackName), source)
        }
        XCTAssertNil(AudioSource(trackName: "Commentary"))
    }

    func testResolvesSavedMicrophone() {
        let mics = [MicrophoneDevice(id: "usb", name: "USB Mic"), MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
        XCTAssertEqual(MicrophoneChoice.resolve(savedID: "usb", available: mics), .device("usb"))
        XCTAssertEqual(MicrophoneChoice.resolve(savedID: nil, available: mics), .systemDefault)
        XCTAssertEqual(MicrophoneChoice.resolve(savedID: "", available: mics), .systemDefault)
    }

    func testUnpluggedMicrophoneFallsBackToSystemInput() {
        let mics = [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
        XCTAssertEqual(MicrophoneChoice.resolve(savedID: "usb", available: mics), .missing(savedID: "usb"))
    }
}
