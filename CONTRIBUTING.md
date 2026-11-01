# Contributing

1. Build as described in the README.
2. Run `swift test`, and `Tests/Integration/run.py` if you touched SIP behaviour (see TESTING.md).
3. Keep Swift 6 strict concurrency clean, and PJSIP types inside `OpenlineBridge`.
4. Put user-visible strings in SwiftUI text or `String(localized:)`, so they reach `Localizable.xcstrings`.
5. Don't report a result that wasn't confirmed by the engine, and don't mark something tested unless it ran against a real server.

`Openline.xcodeproj` is generated from `project.yml`. Edit the YAML and run `xcodegen generate`.

To add a language, add it to `Localizable.xcstrings` in Xcode. No code changes are needed.

Contributions are accepted under GPL-3.0-or-later.
