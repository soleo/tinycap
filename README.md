# Tinycap

A small, native macOS menu-bar screen recorder and screenshot tool. Record a window, a screen or a dragged area and save it as MP4, WebM or GIF, or take a screenshot and mark it up with arrows, text, pixelation and a crop. Everything stays on your Mac.

Requires macOS 15 Sequoia or later. MIT licensed.

## Install

Download the DMG from the [latest release](https://github.com/soleo/tinycap/releases/latest), or use Homebrew:

```sh
brew install --cask soleo/tap/tinycap
```

Tinycap checks for updates itself, so `brew upgrade` leaves it alone unless you pass `--greedy`.

## Status

Recording (capture, trim, MP4 / WebM / GIF export), screenshots with an annotation editor, and daily update checks are in place.

**Capture**
- Menu-bar app with no Dock icon: Screenshot Area / Window / Screen, Record Window / Screen / Area, Open Recent, Settings, Report a Bug, Send Feedback, Quit. Opening the app again while it runs shows a small window with the record buttons.
- Area mode: dimmed overlay on every display, drag a rectangle, live W × H in points, move/resize handles, Return to record, Esc to cancel, floating bar with frame rate and cursor toggles
- Window mode: hover highlights the window under the cursor, click to record; keeps recording when the window moves
- Screen mode: picks the display straight away, or lets you click one when there are several
- ScreenCaptureKit (`SCRecordingOutput`) writes an H.264 master; 15/30/60 fps, Retina or 1×, cursor on/off
- Optional 3-2-1 countdown and click highlights (yellow rings) in every recording mode
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

**Screenshots**
- Same overlays as recording; full Retina resolution; window shots keep transparent corners, shadow optional
- After capture: a floating thumbnail (click to edit, drag out, saved if left alone), or open the editor, copy, or save
- Editor: arrows (Shift snaps to 45°, bend from the middle handle), text with an optional background, pixelate, crop; select, move, resize, delete, undo/redo; six colors plus a picker; V / A / T / P / C switch tools
- Export: ⌘C, ⌘S or drag out; PNG or JPEG at 2× or 1× with the pixel and file size shown; no metadata in the file

**Settings**
- General: launch at login, save folder, file name pattern, daily update check, editable global shortcuts (defaults ⌃⌥⌘4 screenshot area, ⌃⌥⌘A area, ⌃⌥⌘W window, ⌃⌥⌘S screen, ⌃⌥⌘. stop)
- Recording: frame rate, cursor, Retina, click highlights, countdown
- Export: default format, MP4 codec/quality/size, WebM quality/size, GIF preset, loop and fit target
- Screenshot: after capture, format, scale, window shadow, default annotation style
- About: version, build date and commit, links, Report a Bug, Send Feedback, Copy Diagnostics, Acknowledgements

Next: screenshot self-timer, shapes, highlighter and numbered badges; the App Store.

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

### Release DMG

`scripts/make-dmg.sh` builds the direct-download DMG. It does five things:

- builds the universal app, signed with Developer ID and the hardened runtime
- packages it with an Applications shortcut, then signs, notarizes and staples the DMG
- checks the DMG with Gatekeeper
- prints its SHA-256 for the Homebrew cask
- writes `appcast.xml` for the in-app updater, signed with the Sparkle EdDSA key

```sh
# once: store notarization credentials in the login keychain
xcrun notarytool store-credentials tinycap-notary --apple-id you@example.com --team-id TEAMID
# once: create the update-signing key in the keychain; commit Resources/sparkle-public-key.txt
scripts/make-appcast.sh --setup-key

SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tinycap-notary \
  scripts/make-dmg.sh                 # → build/release/Tinycap-<version>.dmg (+ .sha256)

scripts/make-dmg.sh --unsigned        # local test DMG, not notarized
```

Write the user-facing notes in `ReleaseNotes/<version>.md` first. They are converted to HTML and embedded in the appcast, so the update window shows them, and the printed `gh release create` command uses the same file. Attach `appcast.xml` to every release: the app reads it from `releases/latest/download/appcast.xml`. The private signing key stays in the login keychain; back it up to 1Password, because without it existing installs can't verify future updates.

After the release is published, update the Homebrew cask in [soleo/homebrew-tap](https://github.com/soleo/homebrew-tap). The script takes the checksum from the published release:

```sh
scripts/bump-cask.sh ../homebrew-tap   # sets version and sha256 in Casks/tinycap.rb
```

### Updates

The direct build embeds [Sparkle](https://sparkle-project.org) 2.10.0 (`scripts/fetch-sparkle.sh`, pinned by SHA-256) and checks the appcast once a day. The App Store build (`CHANNEL=appstore scripts/build-app.sh`) has no Sparkle; it asks Apple's lookup API for the store version once a day and sends people to the App Store page. Both show a dot on the menu-bar icon, an "Update to Tinycap X.Y…" menu item and one quiet notification per version, and nothing appears while you select, record or export. A direct build made without `Resources/sparkle-public-key.txt` has no updater.

The version comes from the `VERSION` file (or `VERSION=1.2.3`); bump it before tagging a release. The build number is the commit count, for local builds too. Release builds require `nasm`, so the Intel slice gets SIMD.

Two known, harmless messages appear during the release build:

- `ld: warning: no platform load command found in '…libvpx.a[x86_64](….asm.o)'`: nasm doesn't tag its object files with a macOS version, and the linker correctly assumes macOS.
- `hdiutil: WARNING: … is deprecated`: `hdiutil create` still works; the script will move to `diskutil image` once it's verified on a release machine.

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

Tinycap's only network request is the daily update check, which you can turn off in Settings → General. The direct build fetches the appcast from GitHub; the App Store build asks Apple's public lookup API for the latest version by bundle ID. No telemetry, analytics or system profile is sent. The app is sandboxed with a network client entitlement for that check and no microphone or camera entitlements. Recordings are saved to `~/Movies/Tinycap` until you choose another folder in Settings. The only file entitlements are the Movies folder and folders you pick.

## License

MIT. See [LICENSE](LICENSE).
