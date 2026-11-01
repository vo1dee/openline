# Testing

## Unit tests

```bash
swift test
```

They cover validation, routing, the call state machine, dialing, number matching, CSV, reconnection, single-call policy, transfer state, persistence and Keychain. `FakeSIP` is a test double and exists only in the test target.

## Real SIP validation

Docker runs a real Asterisk 20 with test extensions 1001 to 1006. Its passwords are throwaway fixtures.

```bash
docker compose -f Tests/Integration/docker-compose.yml up -d --build
```

```bash
swift build && python3 -I Tests/Integration/run.py
```

`run.py` starts `openline-agent` processes: the production engine, coordinator and database, with sound hardware replaced by a WAV source and recorder. Each side sends a different tone, and the recordings are analysed to prove which audio arrived.

## Real app

```bash
python3 -I Tests/Integration/run_app.py
```

XCUITest drives the sandboxed app through onboarding and registration, closes the main window, and receives and declines a call while an agent dials in. The test account's password is digits only because XCUITest drops letters on non-Latin keyboard layouts. Run `scripts/clean-test-keychain.sh` afterwards.

## Manual checks

These need hardware or a changing network; see KNOWN_LIMITATIONS.md for what has not been verified.

1. Call extension 600 (echo) and confirm you hear yourself on each audio device.
2. Unplug the active device during a call.
3. Toggle Wi-Fi and a VPN, and sleep and wake the Mac, then confirm registration returns.
