# Aria iOS

Native iOS softphone built with SwiftUI, CallKit, and PushKit. Uses [aria-mobile-core](https://github.com/5060-Solutions/aria-mobile-core) (Rust via UniFFI) for SIP signaling and RTP media.

## Features

- **CallKit integration** -- incoming calls show the native iOS call UI, even from lock screen
- **PushKit VoIP push** -- instant wake on incoming calls via APNs VoIP push
- **Full dial pad** -- T9 layout with haptic feedback
- **Mid-call controls** -- mute, hold, speaker, DTMF keypad, encrypted-media indicator
- **Contacts integration** -- search and call from iOS contacts (CNContactStore)
- **Call history** -- incoming, outgoing and missed calls, stored on device; tap to call back
- **Voicemail** -- list, play, mark read and delete messages via the Aria PBX API
- **QR provisioning** -- scan, review the server it points to, then sign in
- **Outgoing calls** -- routed through the push gateway B2BUA
- **On-device transcription** -- optional, device builds with `AI=1` only

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

With `aria-mobile-core` checked out next to this repo:

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
- `aps-environment` -- set from `APS_ENVIRONMENT`: `development` for Debug, `production` for Release
- VoIP push (`com.apple.developer.pushkit.unrestricted-voip`)
- Background modes: audio, voip

## Architecture

```
AriaSoftphone/
  App/
    AriaSoftphoneApp.swift    -- App entry, PushKit registration, session restore
    ContentView.swift          -- Setup flow and tabs (Dialer, Contacts, History, Voicemail, Settings)
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
    PbxApiClient.swift         -- Aria PBX REST client
    KeychainStore.swift        -- Secrets
  Views/
    Dialer/ Call/ Contacts/ Voicemail/ Settings/
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
