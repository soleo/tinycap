# Tinycap

A small, native macOS menu-bar screen recorder. Record a window, a screen or a dragged area and save it as a file. Everything stays on your Mac.

Requires macOS 15 Sequoia or later. MIT licensed.

## Status

Milestones 1–4 are in place: capture, preview with trim, and export to MP4, WebM and GIF.

**Capture**
- Menu-bar app with no Dock icon: Record Window, Record Screen, Record Area, Open Recent, Settings, Quit. Opening the app again while it runs shows a small window with the record buttons.
- Area mode: dimmed overlay on every display, drag a rectangle, live W × H in points, move/resize handles, Return to record, Esc to cancel, floating bar with frame rate and cursor toggles
- Window mode: hover highlights the window under the cursor, click to record; keeps recording when the window moves
- Screen mode: picks the display straight away, or lets you click one when there are several
- ScreenCaptureKit (`SCRecordingOutput`) writes an H.264 master; 15/30/60 fps, Retina or 1×, cursor on/off
- While recording, the menu-bar icon shows the elapsed time; click it to stop

**Preview and export**
- On stop, a preview window plays the clip
- Trim with start/end handles, or press I / O to set them at the playhead; Space plays and pauses (loops inside the trim)
- MP4 as H.264 or HEVC, quality slider, size Full / Half / fixed width, with output size and an estimated file size
- WebM (VP9) with a quality slider and size; keeps the recording's real frame timing, tagged BT.709 so browsers show the right colors
- GIF with presets (Small, Balanced, High), frame rate 5–30, size, 32–256 colors, ordered dithering, loop, duplicate-frame dropping, and "Fit under N MB"
- File-size estimate from a short sample encode, for MP4 and GIF
- After export: Copy (paste the file into Slack, Mail, Finder), Show in Finder, or drag the file out
- Closing an unexported recording asks first; recordings left by a quit or crash are offered again at the next launch

**Settings**
- General: launch at login, save folder, file name pattern, editable global shortcuts (defaults ⌃⌥⌘A area, ⌃⌥⌘W window, ⌃⌥⌘S screen, ⌃⌥⌘. stop)
- Recording: frame rate, cursor, Retina
- Export: default format, MP4 codec/quality/size, WebM quality/size, GIF preset, loop and fit target
- Acknowledgements (third-party licenses) under General

Next (M5): countdown, click highlights, onboarding polish and release packaging.

### How GIFs stay small

Tinycap has its own GIF encoder (`Sources/TinycapCore/GIFEncoder.swift`), written for screen recordings and free of license constraints (gifski is AGPL, which doesn't fit the MIT license or the App Store):

- One palette for the whole clip, built by median cut from frames across the kept range, so colors don't flicker.
- After the first frame, each frame stores only the box that changed, with unchanged pixels transparent.
- Frames where nothing changed are merged into one longer frame.
- Optional ordered dithering, which stays still between frames instead of shimmering.

## Build

```sh
scripts/build-app.sh            # release, universal (arm64 + x86_64) → build/Tinycap.app
CONFIG=debug scripts/build-app.sh
scripts/test.sh                 # unit tests for TinycapCore + WebM bridge round trip
scripts/export-check.sh         # encodes a synthetic recording to MP4, WebM and GIF and verifies the files
scripts/build-vpx.sh            # builds libvpx + libwebm from pinned source (run automatically by the others)
open build/Tinycap.app
```

`swift build` and `swift test` also work, and `Package.swift` opens in Xcode (run `scripts/build-vpx.sh` once first).

### WebM dependencies

WebM export uses [libvpx](https://github.com/webmproject/libvpx) 1.15.0 (VP9) and [libwebm](https://github.com/webmproject/libwebm) 1.0.0.31 (container), both BSD-licensed. `scripts/build-vpx.sh` downloads the tagged source, checks SHA-256 hashes pinned in the script, and builds static universal libraries into `build/vendor` (about 1.5 minutes, then cached). Nothing prebuilt is downloaded. Licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and in the app under Settings → General → Acknowledgements.

Install `nasm` (`brew install nasm`) before building releases. Without it the Intel slice of libvpx is built as portable C, which works but encodes VP9 several times slower on Intel Macs.

The build script calls `swiftc` directly so it also runs inside restricted shells. If the shell is itself sandboxed and SwiftUI macros fail to expand ("swift-plugin-server produced malformed response"), run with `NESTED_SANDBOX=0`.

Signing defaults to ad hoc. Ad-hoc builds get a new signature each time, so macOS asks for Screen Recording permission again after every rebuild. To avoid that, sign with a stable identity:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build-app.sh
```

Other variables: `BUNDLE_ID` (default `app.tinycap.Tinycap`), `VERSION`, `BUILD_NUMBER`, `ARCHS`.

### App icon

`Resources/AppIcon.icns` and `Resources/AppIcon-1024.png` are generated from the reference artwork `TinyCapIcon.png`:

```sh
scripts/make-icon.sh [path/to/TinyCapIcon.png]
```

The script removes the light backdrop around the tile, centers it on Apple's 824 px icon grid and writes every size from 16 to 1024 px. The menu-bar glyph (`MenuBarIcon.swift`) is a pixel-art template image drawn from the same motif: capture corners around a window.

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/TinycapCore` | Pure logic with unit tests: geometry, file naming, settings, size sampling, GIF palette and encoder |
| `Sources/Tinycap/App` | Entry point, menu-bar item, settings, onboarding, save folder |
| `Sources/Tinycap/Selection` | Area, window and screen pickers; recording outline |
| `Sources/Tinycap/Capture` | `ScreenRecorder` (ScreenCaptureKit) |
| `Sources/Tinycap/Recording` | `RecordingCoordinator`: select → record → stop → preview |
| `Sources/Tinycap/Editor` | Preview window: player, trim scrubber, export controls |
| `Sources/Tinycap/Export` | `Exporter` protocol; MP4 (AVAssetReader → AVAssetWriter), WebM (I420 planes → VPXBridge), GIF (vImage → `GIFEncoder`); size estimates |
| `Sources/VPXBridge` | C interface over libvpx and libwebm (encoder + muxer, linked into the app) |
| `Sources/VPXInspect` | Parses and decodes WebM files; used only by the checks |
| `Sources/Tinycap/Hotkeys` | Global shortcuts via Carbon `RegisterEventHotKey`, shortcut recorder |
| `Resources` | Info.plist, entitlements, icon |

## Privacy

Tinycap makes no network connections. The app is sandboxed with no network, microphone or camera entitlements. Recordings are saved to `~/Movies/Tinycap` until you choose another folder in Settings. The only file entitlements are the Movies folder and folders you pick.

## License

MIT. See [LICENSE](LICENSE).
