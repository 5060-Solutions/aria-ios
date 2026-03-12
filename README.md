# Aria iOS

Native iOS softphone built with SwiftUI, CallKit, and PushKit. Uses [aria-mobile-core](https://github.com/5060-Solutions/aria-mobile-core) (Rust via UniFFI) for SIP signaling and RTP media.

## Features

- **CallKit integration** -- incoming calls show the native iOS call UI, even from lock screen
- **PushKit VoIP push** -- instant wake on incoming calls via APNs VoIP push
- **Full dial pad** -- T9 layout with haptic feedback
- **Mid-call controls** -- mute, hold, speaker, DTMF keypad
- **Contacts integration** -- search and call from iOS contacts (CNContactStore)
- **Call history** -- recent calls with direction indicators
- **Settings** -- gateway URL, API key, SIP credentials, registration status
- **Outgoing calls** -- routed through the push gateway B2BUA

## Requirements

- iOS 17.0+
- Xcode 15+
- Rust toolchain with iOS targets:
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```

## Building

### 1. Build the Rust core

```bash
cd ../aria-mobile-core
./build-ios.sh
```

This produces an XCFramework containing the static library and UniFFI-generated Swift bindings.

### 2. Add to Xcode

1. Open `AriaSoftphone.xcodeproj` in Xcode
2. Add the generated XCFramework to the project
3. Build and run on device or simulator

### 3. Entitlements

The app requires:
- `aps-environment` (push notifications)
- VoIP push entitlement
- Background modes: audio, voip, remote-notification

## Architecture

```
AriaSoftphone/
  App/
    AriaSoftphoneApp.swift    -- App entry, PushKit registration
    ContentView.swift          -- Tab navigation (Dialer, Contacts, History, Settings)
    SipEngineManager.swift     -- ObservableObject bridging Rust engine to SwiftUI
  CallKit/
    CallManager.swift          -- CXProviderDelegate, incoming/outgoing call handling
  Push/
    PushHandler.swift          -- PKPushRegistryDelegate, VoIP push processing
  Bridge/
    AriaMobileCore.swift       -- UniFFI stub types (replaced by generated code at build)
  Views/
    Dialer/DialerView.swift    -- Dial pad UI
    Call/CallView.swift        -- Full-screen active call UI
    Call/HistoryView.swift     -- Call history list
    Contacts/ContactsView.swift -- iOS contacts integration
    Settings/SettingsView.swift -- Account configuration
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
