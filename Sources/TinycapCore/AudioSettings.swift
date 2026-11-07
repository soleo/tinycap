import Foundation

/// A sound source in a recording (AU-1, AU-2). Each one is its own track in the master
/// and in exported MP4s (AU-3), named so the preview and export can tell them apart.
public enum AudioSource: String, Sendable, CaseIterable, Identifiable {
    case system
    case microphone
    /// A connected iPhone or iPad's own sound (DV-5).
    case device

    public var id: String { rawValue }

    /// Track name written into the master and the exported MP4.
    public var trackName: String {
        switch self {
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        case .device: return "Device Audio"
        }
    }

    /// Label for the preview's Sound switches.
    public var displayName: String {
        switch self {
        case .system: return "System audio"
        case .microphone: return "Microphone"
        case .device: return "Device audio"
        }
    }

    public init?(trackName: String) {
        guard let source = Self.allCases.first(where: { $0.trackName == trackName }) else { return nil }
        self = source
    }

    /// AAC settings for the master and MP4 export: 48 kHz, mono for the microphone,
    /// stereo otherwise.
    public var channelCount: Int { self == .microphone ? 1 : 2 }
    public var bitrate: Int { self == .microphone ? 96_000 : 128_000 }
    public static let sampleRate = 48_000
}

/// An input device the microphone can record from.
public struct MicrophoneDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum MicrophoneChoice {
    public enum Resolved: Sendable, Equatable {
        /// Use this device.
        case device(String)
        /// Use the system's input device.
        case systemDefault
        /// The saved device isn't connected; the system input is used instead.
        case missing(savedID: String)
    }

    /// Which input to record from (AU-2): the saved device if it's connected, otherwise
    /// the system input, flagged so the user can be told.
    public static func resolve(savedID: String?, available: [MicrophoneDevice]) -> Resolved {
        guard let savedID, !savedID.isEmpty else { return .systemDefault }
        return available.contains { $0.id == savedID } ? .device(savedID) : .missing(savedID: savedID)
    }
}
