# Known limitations

## Not tested

Nothing here should be assumed to work until checked.

- **Real sound hardware, beyond one echo call.** One outgoing call to the PBX echo extension was confirmed by ear on one Mac with the default devices, including the microphone permission prompt. Echo cancellation on open speakers, ringtone output, and the Settings microphone and speaker tests have not been checked.
- **Answering in the app.** Answer was exercised by the integration agent, not by clicking it in the app.
- **Bluetooth, AirPods, USB switching, and unplugging a device during a call.**
- **Wi-Fi loss, VPN changes and sleep/wake.** Recovery was tested with a PBX restart only.
- **DNS SRV, DNS failure, outbound proxies on a live server, STUN, ICE, TURN and IPv6.** Code paths exist; none ran against a server.
- **A TLS certificate that chains to a trusted CA.** TLS calls were tested with verification off, and refusal of an untrusted certificate with it on.
- **The visual design.** The UI was exercised by XCUITest, but no person or screenshot has reviewed layout, Dark Mode, Liquid Glass, or VoiceOver. Contacts, Recents, Settings and CSV import have unit tests below the views only.
- **Launch at Login, notifications, and other PBXs than Asterisk 20.**
- **Typing letters in UI tests.** XCUITest drops letters on the non-Latin layout used for testing, so UI test accounts use digits.

## Behaviour

- One active call at a time. Other incoming calls get 486 Busy Here.
- A REFER from the far end is declined with 603, because it would start a second call. Transfers run by a PBX are unaffected.
- Host names resolve through DNS servers only. `/etc/hosts` entries and `.local` names don't resolve; use an IP address in Registrar.
- Codec order applies to all accounts, because PJSIP keeps it per endpoint.
- Device selection uses device names, so two devices with one name can't be told apart.
- DTLS-SRTP is not available, because it needs OpenSSL. SRTP uses SDES.
- Digest SHA-256 authentication has not been checked with this TLS backend.
- Detailed logging applies after relaunch.
- The English string catalog is complete; no Ukrainian translation exists yet.
- Blind transfer gives up waiting after 32 s and restores the call if no final NOTIFY arrives.

## Distribution

- Builds are ad-hoc signed and not notarized. No signing certificate was available.
- An ad-hoc rebuild has a new code signature, so Keychain may ask again for stored passwords.

## Test rig

Docker Desktop's UDP proxy can change a client's source port and hides unregistration from Asterisk, so `run_app.py` restarts the PBX and may redial. This is rig behaviour; a client behind an aggressive NAT can see the same missed INVITE until its next keepalive or re-registration.
