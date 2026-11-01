# Architecture

```
App/Openline             SwiftUI views, menu bar, call panel, system services
Sources/OpenlineKit      PhoneCoordinator: lifecycle, policies, history
Sources/OpenlineStore    SQLite (GRDB) and Keychain
Sources/OpenlineCore     Models, call state machine, dialing, matching, CSV. No dependencies
Sources/OpenlineSIP      PJSIPService: SIPService over the bridge
Sources/OpenlineBridge   Objective-C++ facade over PJSUA2
Vendor/CPJSIP.xcframework  Static PJSIP and Opus, built by scripts/
```

Each layer depends only on those below it. UI code never sees a PJSIP type, and `OpenlineCore` compiles without PJSIP.

## SIP threading

`OLEngine` owns one dedicated thread, which creates the endpoint and pumps it with `threadCnt = 0` and `mainThreadOnly = true`. Every public method queues a job for that thread, and every PJSUA2 callback runs on it, so engine objects are never touched concurrently and the main thread never blocks on SIP. Callbacks become immutable `OLEvent`s, then `SIPEvent`s in an `AsyncStream`. Conference-bridge audio runs on PJSIP's own threads.

`pj::Call` objects may not be deleted inside their own callback, so `Core::retire` defers deletion to the next loop turn. Calls are addressed by a UUID handle because PJSUA reuses its integer ids.

## State truth

- `SIPCall.apply` validates transitions in `CallTransition`. Invalid events, such as a late callback after a call ended, are ignored.
- `makeCall` returning means only that an INVITE went out. `Established` needs the CONFIRMED state. `Held` needs a media update reporting local hold. Mute is published after the engine has rerouted audio.
- `Registered` needs a 2xx with a non-zero expiry.

## Routing

The address of record uses the SIP domain. When the registrar differs from the domain, or a port or non-UDP transport is set, requests are routed through the registrar with a loose `Route`, keeping the request URI on the domain. An explicit outbound proxy takes precedence. See `SIPAccount.routeURI`.

## Reconnection

PJSIP's own retry is off (`retryIntervalSec = 0`). `PhoneCoordinator` retries with `ReconnectPolicy`: exponential from 5 s to 300 s with ±20% jitter. Credential, 403, 404 and TLS failures are never retried. Network changes and wake call `handleIpChange`, and restart backoff only for accounts in a retryable failure.

## Why the call UI is an AppKit panel

SwiftUI scenes need an environment action to open and may be restored as closed. `CallPanelController` shows an `NSPanel` from any state, including with every other window closed.

## Audio

The conference bridge runs at 48 kHz mono with WebRTC AEC3 as the only echo canceller. Devices are selected by name because PJSIP indices change on refresh. `audioHardwareChanged` refreshes and re-applies the selection when Core Audio reports a change. A local hold cuts the microphone from the bridge, because a `sendonly` stream keeps transmitting.
