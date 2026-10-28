import AVKit
import SwiftUI
import TinycapCore

/// AVPlayerView without its own controls; Tinycap draws its own scrubber.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.setAccessibilityLabel("Recording preview")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Timeline with start/end trim handles and a playhead (ED-2). Click or drag the track to
/// seek; drag a handle to trim. Handles are adjustable with VoiceOver in 0.1 s steps.
struct TrimScrubber: View {
    let duration: Double
    let start: Double
    let end: Double
    let playhead: Double
    let onSeek: (Double) -> Void
    let onStart: (Double) -> Void
    let onEnd: (Double) -> Void

    private static let space = "trimScrubber"
    private let handleWidth: CGFloat = 10
    private let height: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - handleWidth * 2, 1)
            let x = { (t: Double) -> CGFloat in handleWidth + CGFloat(duration > 0 ? t / duration : 0) * width }
            let time = { (px: CGFloat) -> Double in Double((px - handleWidth) / width) * duration }

            ZStack(alignment: .topLeading) {
                // Track, with the kept range highlighted and framed.
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: width, height: height)
                    .offset(x: handleWidth)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: max(x(end) - x(start), 0), height: height)
                    .overlay(alignment: .top) { Rectangle().fill(Color.accentColor).frame(height: 2) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.accentColor).frame(height: 2) }
                    .offset(x: x(start))

                // Playhead.
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: height + 6)
                    .offset(x: x(playhead) - 1, y: -3)
                    .accessibilityHidden(true)

                handle(edge: .leading, value: start, label: "Trim start")
                    .offset(x: x(start) - handleWidth)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { g in
                        onStart(time(g.location.x + handleWidth / 2))
                    })
                handle(edge: .trailing, value: end, label: "Trim end")
                    .offset(x: x(end))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { g in
                        onEnd(time(g.location.x - handleWidth / 2))
                    })
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { g in
                    onSeek(min(max(time(g.location.x), start), end))
                }
            )
            .accessibilityElement(children: .contain)
        }
        .frame(height: height + 6)
        .padding(.top, 3)
    }

    private func handle(edge: HorizontalEdge, value: Double, label: String) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 5 : 0,
            bottomLeadingRadius: edge == .leading ? 5 : 0,
            bottomTrailingRadius: edge == .trailing ? 5 : 0,
            topTrailingRadius: edge == .trailing ? 5 : 0
        )
        .fill(Color.accentColor)
        .frame(width: handleWidth, height: height)
        .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 12))
        .contentShape(Rectangle().inset(by: -6))
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(TimeText.precise(value))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            if edge == .leading { onStart(value + step) } else { onEnd(value + step) }
        }
    }
}

enum TimeText {
    /// "0:03.2"
    static func precise(_ t: Double) -> String {
        let clamped = max(t, 0)
        let tenths = Int((clamped * 10).rounded(.down)) % 10
        return "\(ElapsedTime.format(clamped)).\(tenths)"
    }
}
