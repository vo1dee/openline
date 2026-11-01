# Third-party software

Versions are pinned in `scripts/build-native-deps.sh` and `Package.swift`.

| Component | Version | License | Use |
|---|---|---|---|
| PJSIP (pjproject) | 2.17 | GPL-2.0-or-later | SIP and media engine |
| Opus | 1.6.1 | BSD-3-Clause | Codec |
| libsrtp (in pjproject) | bundled | BSD-3-Clause | SRTP |
| WebRTC AEC3 and libwebrtc parts (in pjproject) | bundled | BSD-3-Clause | Echo cancellation |
| libresample (in pjproject) | bundled | LGPL-2.1, per its `COPYING` | Resampling |
| GRDB.swift | 7.11.1 | MIT | SQLite |

Copyright notices are in each component's source: run `scripts/build-native-deps.sh` and see `Vendor/src`.

## Compatibility review

PJSIP's source headers grant "version 2 of the License, or (at your option) any later version", so it may be combined into a GPL-3.0-or-later work. The BSD, MIT and LGPL components are GPL-3.0 compatible.

PJSIP's optional iLBC, GSM, Speex, G.722.1, AMR and SILK codecs are excluded. OpenSSL is not used: TLS comes from Apple's Network.framework, a system library.

## Source obligations

Binary distributors must offer the corresponding source of Openline and the exact dependency versions. This repository and the pinned, checksummed downloads in the build script provide that for an unmodified build.

The app icon and ringtones are not third-party content: `scripts/make-app-icon.swift` draws the icon and `RingtoneSynth` generates the tones.
