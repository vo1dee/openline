# Openline

A free, native SIP softphone for macOS 27 on Apple Silicon, written in Swift and SwiftUI on top of PJSIP.

- Multiple SIP accounts on any standards-compliant server or PBX
- Calls with mute, hold, DTMF and blind transfer
- Local contacts and call history
- Keeps running in the menu bar, so calls still arrive with the window closed
- No accounts, no cloud, no telemetry. Passwords live in the Keychain

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

[ARCHITECTURE.md](ARCHITECTURE.md), [TESTING.md](TESTING.md), [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md), [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [CHANGELOG.md](CHANGELOG.md), [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
