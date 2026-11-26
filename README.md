# Aria iOS

Native iOS softphone built with SwiftUI, CallKit, and PushKit. Uses [aria-mobile-core](https://github.com/5060-Solutions/aria-mobile-core) (Rust via UniFFI) for SIP signaling and RTP media.

## Features

- **CallKit integration** -- incoming calls show the native iOS call UI, even from lock screen
- **PushKit VoIP push** -- instant wake on incoming calls via APNs VoIP push
- **Full dial pad** -- T9 layout with haptic feedback
- **Mid-call controls** -- mute, hold, speaker, DTMF keypad, blind transfer, encrypted-media indicator
- **Contacts integration** -- search and call from iOS contacts (CNContactStore)
- **Call history** -- incoming, outgoing and missed calls, stored on device; tap to call back
- **Messages** -- business texting (SMS/MMS) on the numbers a seat is assigned: conversations per inbox with unread state, threads with delivery status, photos, a segment counter, live refresh (WebSocket plus a 15 s poll), and notification taps that open the thread. Uses the extension-login JWT against `/api/v1/tenants/{id}/messaging/...`
- **Call move** -- a banner ("Call with X on Desk phone · Move here") when a call is live on another of your devices, and "Move to…" in the call's menu. The PBX swaps the device leg and the far party stays connected; this app never sends or accepts SIP `Replaces`. A move this phone asked for is answered straight away, with no ringing screen (it needs `moveId` in the VoIP push, see below)
- **Call handoff** -- Settings > Call handoff: suggest nearby calls, move a call when you leave, and an opt-in, off-by-default Bluetooth LE hint (foreground only). Wi-Fi is reported as a SHA-256 of the interface's subnet, never the SSID, so no Location permission is needed
- **Hold for me** -- in the call's overflow menu on an answered outgoing call: the PBX waits on hold and rings you when a person answers. A card and a Live Activity show the wait, and Settings > Hold for me sets the default greeting. Hidden unless `GET /api/v1/me` lists `hold_for_me` in `features`
- **Voicemail** -- list, play, mark read and delete messages via the Aria PBX API
- **QR provisioning** -- scan, review the server it points to, then sign in
- **Outgoing calls** -- routed through the push gateway B2BUA
- **On-device transcription** -- optional, device builds with `AI=1` only

### Push payload for a moved call

The PBX's INVITE for a move carries `X-Aria-Move: <move_id>`. The app reads it from the VoIP push (`moveId`, optionally `moveFrom` with the label of the device the call leaves), because PushKit needs the call reported before anything is fetched. The push gateway must add those keys to the push for an INVITE with that header.

### Hold for me

Every Hold for me surface is hidden until the PBX offers it (`features` contains `"hold_for_me"`). The call screen shows a wait card, and the `AriaHoldActivity` extension shows the Live Activity on the Lock Screen and in the Dynamic Island. When the far party is back, the PBX rings the phone with `X-Aria-Hold-Return`, and the incoming screen says "They're back" with what the assistant heard.

Alert pushes with `data.type == "hold_wait"` and `aps.category` `HOLD_WAIT` get a "Call again" action that redials `remote_number`; a plain tap opens the app to a banner with the same button. The category is always registered and does nothing unless a PBX that supports Hold for me sends such a push.

For whoever signs the build: register the App ID `com.solutions5060.aria.holdactivity` (the Live Activity extension) and give it a provisioning profile. No App Group is needed.

## Requirements

- iOS 16.0+ (the deployment target in `project.yml`)
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Rust toolchain with iOS targets:
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```

## Building

### 1. Build the Rust core

With `aria-mobile-core` checked out next to this repo (or point `RUST_DIR` at
another checkout, e.g. `RUST_DIR=../_wt-core-ios ./build-rust.sh`):

```bash
./build-rust.sh            # release; ./build-rust.sh debug for a debug core
AI=1 ./build-rust.sh       # also compile on-device transcription (device slice only)
```

This builds the static libraries, writes `AriaMobileCore.xcframework` at the
repo root and regenerates the UniFFI Swift bindings in `AriaSoftphone/Bridge/`.
The app links the real core; there is no stub bridge.

### 2. Generate the project and build

```bash
xcodegen generate
xcodebuild -project AriaSoftphone.xcodeproj -scheme AriaSoftphone \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project AriaSoftphone.xcodeproj -scheme AriaSoftphone \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`project.yml` is the source of truth; regenerate after changing it. The
simulator slice is arm64 only.

### 3. Entitlements

The app requires:
- `aps-environment` -- set from `APS_ENVIRONMENT`: `development` for Debug, `production` for Release. It also covers the regular APNs token the app registers for text-message alerts (sent to the gateway as `alert_token`); PushKit stays the call path.
- Background modes: audio, voip (VoIP pushes via PushKit need only the Push
  Notifications capability and the `voip` background mode; every push is
  reported to CallKit)

## Architecture

```
AriaSoftphone/
  App/
    AriaSoftphoneApp.swift    -- App entry, PushKit registration, session restore
    ContentView.swift          -- Setup flow and tabs (Dialer, Contacts, History, Voicemail, Messages, Settings)
    SipEngineManager.swift     -- Owns the Rust engine; restore, registration, event handler
  CallKit/
    CallManager.swift          -- CXProviderDelegate, call lifecycle, audio route
  Push/
    PushHandler.swift          -- PKPushRegistryDelegate, VoIP push processing
  Bridge/
    aria_mobile.swift          -- UniFFI-generated bindings (written by build-rust.sh)
  Services/
    AccountSettings.swift      -- Stored account and its defaults
    AccountSession.swift       -- PBX login, gateway registration, sign-out
    AudioBridge.swift          -- AVAudioEngine <-> core PCM, started by CallKit
    CallHistoryStore.swift     -- On-device call history
    VoicemailService.swift     -- Voicemail via the Aria PBX API
    MessagingService.swift     -- SMS/MMS inboxes, threads, live refresh (REST + WebSocket)
    PbxApiClient.swift         -- Aria PBX REST client
    KeychainStore.swift        -- Secrets
  Views/
    Dialer/ Call/ Contacts/ Voicemail/ Messages/ Settings/
AriaSoftphoneTests/            -- Unit tests
```

## Ecosystem

| Component | Repository |
|-----------|-----------|
| Desktop softphone | [aria](https://github.com/5060-Solutions/aria) |
| RTP media engine | [rtp-engine](https://github.com/5060-Solutions/rtp-engine) |
| SIP protocol library | [aria-sip-core](https://github.com/5060-Solutions/aria-sip-core) |
| Push gateway | [aria-push-gateway](https://github.com/5060-Solutions/aria-push-gateway) |
| Mobile core (Rust) | [aria-mobile-core](https://github.com/5060-Solutions/aria-mobile-core) |
| **iOS app** | **aria-ios** |
| Android app | [aria-android](https://github.com/5060-Solutions/aria-android) |

## License

MIT
