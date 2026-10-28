# Tinycap

A small, native macOS menu-bar screen recorder. Record a window, a screen or a dragged area and save it as a file. Everything stays on your Mac.

Requires macOS 15 Sequoia or later. MIT licensed.

## Status

Milestone 1 (capture) is in place:

- Menu-bar app with no Dock icon: Record Window, Record Screen, Record Area, Open Recent, Settings, Quit
- Area mode: dimmed overlay on every display, drag a rectangle, live W × H in points, move/resize handles, Return to record, Esc to cancel, floating bar with frame rate and cursor toggles
- Window mode: hover highlights the window under the cursor, click to record; keeps recording when the window moves
- Screen mode: picks the display straight away, or lets you click one when there are several
- Recording with ScreenCaptureKit (`SCRecordingOutput`) to an H.264 master, 15/30/60 fps, Retina or 1×, cursor on/off
- While recording the menu-bar icon shows the elapsed time; click it to stop
- On stop the clip is saved as MP4 (no re-encode) and revealed in Finder
- Global shortcuts: ⌃⌥⌘A area, ⌃⌥⌘W window, ⌃⌥⌘S screen, ⌃⌥⌘. stop
- First-run window that explains and requests the Screen Recording permission
- Settings: launch at login, save folder, file name pattern, frame rate, cursor, Retina

Next (see the PRD milestones): preview window with trim, MP4 quality and scale, editable shortcuts (M2); GIF export (M3); WebM export (M4); countdown, click highlights and release packaging (M5).

## Build

```sh
scripts/build-app.sh            # release, universal (arm64 + x86_64) → build/Tinycap.app
CONFIG=debug scripts/build-app.sh
scripts/test.sh                 # unit tests for TinycapCore
open build/Tinycap.app
```

`swift build` and `swift test` also work, and `Package.swift` opens in Xcode.

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
| `Sources/TinycapCore` | Pure logic with unit tests: coordinate conversion, resize handles, file naming, settings |
| `Sources/Tinycap/App` | Entry point, menu-bar item, settings, onboarding, save folder |
| `Sources/Tinycap/Selection` | Area, window and screen pickers; recording outline |
| `Sources/Tinycap/Capture` | `ScreenRecorder` (ScreenCaptureKit) |
| `Sources/Tinycap/Recording` | `RecordingCoordinator`: select → record → stop → save |
| `Sources/Tinycap/Export` | `Exporter` protocol and the MP4 exporter |
| `Sources/Tinycap/Hotkeys` | Global shortcuts via Carbon `RegisterEventHotKey` |
| `Resources` | Info.plist, entitlements, icon |

## Privacy

Tinycap makes no network connections. The app is sandboxed with no network, microphone or camera entitlements. Recordings are saved to `~/Movies/Tinycap` until you choose another folder in Settings. The only file entitlements are the Movies folder and folders you pick.

## License

MIT. See [LICENSE](LICENSE).
