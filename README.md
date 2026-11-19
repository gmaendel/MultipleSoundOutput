# MultipleSoundOutput

A small menu bar app that plays sound through **both Apple Studio Displays at once**, with a working volume slider and working keyboard volume keys.

It replaces [MultiSoundChanger](https://github.com/rlxone/MultiSoundChanger), which is Intel-only and no longer maintained. It isn't a port of that code: it's a fresh, native Apple Silicon app built on the same idea.

## Why it's needed

macOS can play to several outputs through a **Multi-Output Device** (Audio MIDI Setup). But a Multi-Output Device has no volume control of its own. The volume keys show a "not allowed" symbol and the Sound menu slider is greyed out. This app gets around that by setting the volume (and mute) on **each display** in the Multi-Output Device.

## What it does

- **Menu bar menu**: a volume slider, a list of outputs, and a **Both Displays** item that sends sound to every connected display speaker.
- **Keyboard volume keys** (🔉 🔊 🔇) work while the Multi-Output Device is selected, with an on-screen level indicator. Hold **⇧⌥** for finer steps. For any other output, the keys pass through to macOS as usual.
- **Switches automatically** to both displays at launch, after the Mac wakes, and when a display is plugged back in. When you unplug the displays, it moves sound back to the MacBook speakers (or headphones, if they're plugged in), so you're never left on a Multi-Output Device with nothing connected. It doesn't override you when you pick another output by hand. You can turn this off in the menu (**Switch Output Automatically**).
- **Reuses your existing Multi-Output Device** from Audio MIDI Setup. If there isn't one, it creates one named "All Displays", with drift correction on the second display.
- **Open at Login** toggle.
- **Command line** for scripts and Shortcuts:

  ```bash
  /Applications/MultipleSoundOutput.app/Contents/MacOS/MultipleSoundOutput --help
  ```

  Commands: `--status`, `--list`, `--volume 0-100`, `--up`, `--down`, `--mute`, `--unmute`, `--use-displays`, `--select <name|uid>`.

## Install

Requires macOS 14 Sonoma or later. With [Homebrew](https://brew.sh):

```bash
brew install --cask gmaendel/tap/multiplesoundoutput
```

Or download the zip from [Releases](https://github.com/gmaendel/MultipleSoundOutput/releases), unzip it and move **MultipleSoundOutput** to Applications. Releases are signed with a Developer ID and notarized by Apple.

## First run

1. Open `/Applications/MultipleSoundOutput.app`. A speaker icon appears in the menu bar.
2. macOS asks to allow **Accessibility** for MultipleSoundOutput. This is needed only for the keyboard volume keys. If you dismissed the prompt, choose **Allow Keyboard Volume Keys…** from the menu and turn on MultipleSoundOutput in System Settings › Privacy & Security › Accessibility.
3. Optional: hide the system Sound icon (System Settings › Control Center › Sound › Don't Show in Menu Bar) and remove MultiSoundChanger from Login Items so the two apps don't compete for the volume keys.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/build.sh            # builds build/MultipleSoundOutput.app
scripts/build.sh --install  # also copies it to /Applications and relaunches it
```

Or run `xcodegen generate` and open `MultipleSoundOutput.xcodeproj` in Xcode.

The app is signed with the Apple Development certificate of the team in `project.yml`. Because the identity stays the same, macOS keeps the Accessibility permission across rebuilds. To build with your own certificate, change `DEVELOPMENT_TEAM` in `project.yml`. To build without one, use ad-hoc signing (you'll have to grant Accessibility again after every build):

```bash
CODE_SIGN_IDENTITY=- scripts/build.sh
```

## Releasing

```bash
scripts/release.sh            # signs with Developer ID, notarizes, zips build/MultipleSoundOutput-<version>.zip
scripts/release.sh --publish  # also creates the GitHub release and updates the Homebrew cask
```

Set the version in `project.yml` (`MARKETING_VERSION`) first, and commit and push. The script needs a **Developer ID Application** certificate and a saved notarization login:

```bash
xcrun notarytool store-credentials MultipleSoundOutput --apple-id <Apple ID> --team-id <team ID>
```

The cask lives in [gmaendel/homebrew-tap](https://github.com/gmaendel/homebrew-tap).

## Layout

| Path | What's in it |
| --- | --- |
| `Sources/Audio/CoreAudio.swift` | Typed wrappers around the CoreAudio HAL property API |
| `Sources/Audio/AudioDevice.swift` | Device snapshot, display detection, per-device volume and mute |
| `Sources/Audio/AudioController.swift` | Default output, aggregate volume, Multi-Output lookup and creation, change listeners |
| `Sources/Input/MediaKeyMonitor.swift` | Event tap that catches the volume keys |
| `Sources/UI/` | Menu bar menu, volume slider, on-screen volume indicator |
| `Sources/App/` | App startup, settings, command-line mode |
| `scripts/build.sh`, `scripts/release.sh` | Build, and signed and notarized releases |
| `scripts/make-icon.swift` | Draws the app icon |

## License

MIT. See [LICENSE](LICENSE).
