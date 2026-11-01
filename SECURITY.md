# Security

Report vulnerabilities privately to the maintainers, not in a public issue.

## Design

- SIP and TURN passwords are stored only in the Keychain. `SIPAccount` has no password property, and a test asserts it never encodes one.
- TLS uses Network.framework with the system trust store and hostname verification. There is no setting to disable it. `skipTLSVerificationForTesting` exists only for the integration agent, and the app never sets it.
- A PBX with a private CA works once you trust that certificate in Keychain Access.
- SDES-SRTP keys travel in SDP, so the UI warns unless signalling uses TLS.
- The app is sandboxed with hardened runtime enabled. Its entitlements are network client and server, audio input and user-selected files.
- Exported diagnostics pass through `DiagnosticsSanitizer`, which removes authentication headers, nonces and passwords. SIP logging is off by default and held in memory.
- No telemetry, analytics or network traffic other than what your accounts configure.
