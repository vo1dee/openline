<p align="center">
  <img src="App/Openline/Resources/Assets.xcassets/AppIcon.appiconset/icon-256.png" width="128" height="128" alt="Openline icon">
</p>

<h1 align="center">Openline</h1>

<p align="center">
  A free, native SIP softphone for macOS 27 on Apple Silicon, written in Swift and SwiftUI on top of PJSIP.
</p>

<p align="center">
  <a href="https://github.com/vo1dee/openline/releases/latest"><img src="https://img.shields.io/github/v/release/vo1dee/openline" alt="Latest release"></a>
  <a href="https://github.com/vo1dee/openline/actions/workflows/ci.yml"><img src="https://github.com/vo1dee/openline/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/vo1dee/openline" alt="License: GPL-3.0-or-later"></a>
  <img src="https://img.shields.io/badge/macOS-27-blue" alt="macOS 27">
</p>

- Multiple SIP accounts on any standards-compliant server or PBX
- Calls with mute, hold, DTMF and blind transfer
- Local contacts and call history
- Keeps running in the menu bar, so calls still arrive with the window closed
- No accounts, no cloud, no telemetry. Passwords live in the Keychain

## Download

Get the DMG from [Releases](https://github.com/vo1dee/openline/releases/latest) and drag Openline to Applications.

Releases are ad-hoc signed and not notarized, so macOS blocks the first open. Try opening the app once, then allow it under System Settings > Privacy & Security > Open Anyway. See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) for what has and hasn't been tested.

## Build

Needs macOS 27, Xcode 27 and Homebrew.

```bash
brew install xcodegen
```

```bash
./scripts/build-native-deps.sh
```

```bash
xcodegen generate
```

```bash
open Openline.xcodeproj
```

Run the **Openline** scheme. `build-native-deps.sh` downloads pinned, checksum-verified PJSIP and Opus and takes about two minutes.

To make an app and DMG in `build/release`:

```bash
./scripts/package.sh
```

The result is ad-hoc signed unless `SIGN_IDENTITY` is set. Ad-hoc builds are not notarized, so macOS asks for confirmation on first open, and only run as built on your own Mac.

## Documentation

[ARCHITECTURE.md](ARCHITECTURE.md), [TESTING.md](TESTING.md), [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md), [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [SECURITY.md](SECURITY.md), [CHANGELOG.md](CHANGELOG.md), [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
