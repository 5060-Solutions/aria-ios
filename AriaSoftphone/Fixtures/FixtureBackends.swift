#if DEBUG
import Foundation

// MARK: - Bootstrap

/// Installs fixture state at launch. Called from the app delegate instead of
/// the engine restore, push registration and notification setup.
enum FixtureBootstrap {
    /// Main thread, before the first view is drawn.
    @MainActor
    static func apply(scene: FixtureScene) {
        resetDefaults()
        if scene.isSignedIn {
            writeAccount(FixtureData.account)
            SipEngineManager.shared.isRegistered = true
            SipEngineManager.shared.registrationError = nil
            SipEngineManager.shared.deviceId = FixtureData.account.pbxDeviceId
            SipEngineManager.shared.isRecovering = FixtureMode.isReconnecting
        }
        installHoldForMe(scene: scene)
        AccountSession.shared.applyFixture(signedIn: scene.isSignedIn)
        CallManager.shared.loadFixture(calls: FixtureData.calls(for: scene))
    }

    /// Hold for me answers from memory, and is offered unless the launch
    /// arguments turn the flag off.
    @MainActor
    private static func installHoldForMe(scene: FixtureScene) {
        let model = HoldForMeModel.shared
        model.reset()
        model.backend = FixtureHoldForMeBackend()
        model.resolveCallId = { $0.callId }
        model.setAvailable(FixtureMode.offersHoldForMe)
        model.activities = HoldActivityController(facade: FixtureActivityFacade())
        if scene == .holdWaiting {
            let started = Date().addingTimeInterval(-(12 * 60 + 34))
            model.handle(.state(
                HoldWait(holdWaitId: "fx-hold-1", callId: "fx-call-1", state: "waiting", greeting: .line,
                         startedAt: started, stateSince: started, maxWaitSecs: 10800, falseAlarms: 0,
                         remote: .init(number: "4155550142", name: nil), ringReason: nil, endedReason: nil),
                transcript: []))
        }
    }

    /// Start from empty settings, so a previous run or a real account on the
    /// same simulator cannot leak into a fixture.
    private static func resetDefaults() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        // A preferences domain left on the simulator outside the app's
        // container (by another tool) still answers reads after the app's
        // own domain is removed. Empty values in the app's domain take
        // precedence over it, so a fixture starts signed out for sure.
        for key in [AccountSettings.Key.username, AccountSettings.Key.displayName, AccountSettings.Key.domain] {
            UserDefaults.standard.set("", forKey: key)
        }
    }

    private static func writeAccount(_ account: FixtureData.Account) {
        let defaults = UserDefaults.standard
        typealias Key = AccountSettings.Key
        defaults.set(account.username, forKey: Key.username)
        defaults.set(account.displayName, forKey: Key.displayName)
        defaults.set(account.domain, forKey: Key.domain)
        defaults.set(account.registrar, forKey: Key.registrar)
        defaults.set(account.port, forKey: Key.port)
        defaults.set(account.transport, forKey: Key.transport)
        defaults.set(account.apiUrl, forKey: Key.apiUrl)
        defaults.set(account.gatewayUrl, forKey: Key.gatewayUrl)
        defaults.set(account.voicemailNumber, forKey: Key.voicemailNumber)
        defaults.set(account.extensionId, forKey: Key.extensionId)
        defaults.set(account.tenantId, forKey: Key.tenantId)
        defaults.set(account.pbxDeviceId, forKey: Key.pbxDeviceId)
    }
}

// MARK: - Contacts

struct FixtureContactsSource: ContactsSource {
    var contacts = FixtureData.contacts
    var accessGranted = true

    var isAuthorized: Bool { accessGranted }
    func requestAccess() async throws -> Bool { accessGranted }
    func fetchContacts() throws -> [ContactEntry] { contacts }
}

// MARK: - Hold for me

/// Starts and cancels waits in memory, recording each into `FixtureEvents`.
struct FixtureHoldForMeBackend: HoldForMeBackend {
    var saved = HoldSettings(greeting: .line, assistantAvailable: true, maxWaitSecs: 10800)

    private func record(_ event: String) async {
        await MainActor.run { FixtureEvents.shared.holdForMe.append(event) }
    }

    private func wait(callId: String, greeting: HoldGreeting, name: String?, state: String = "waiting") -> HoldWait {
        let now = Date()
        return HoldWait(
            holdWaitId: "fx-hold-1", callId: callId, state: state, greeting: greeting,
            startedAt: now, stateSince: now, maxWaitSecs: saved.maxWaitSecs, falseAlarms: 0,
            remote: .init(number: FixtureData.activeCaller.uri, name: name),
            ringReason: nil, endedReason: state == "ended" ? "hung_up" : nil
        )
    }

    func start(callId: String, greeting: HoldGreeting?, displayName: String?) async throws -> HoldWait {
        let used = greeting ?? saved.greeting
        await record("holdForMe.started:\(used.rawValue)")
        return wait(callId: callId, greeting: used, name: displayName)
    }

    func cancel(callId: String, action: String) async throws -> HoldWait {
        await record("holdForMe.cancelled:\(action)")
        return wait(callId: callId, greeting: saved.greeting, name: nil, state: "ended")
    }

    func stillOnHold(callId: String) async throws -> HoldWait {
        await record("holdForMe.stillOnHold")
        return wait(callId: callId, greeting: saved.greeting, name: nil)
    }

    func openWaits() async throws -> [HoldWait] { [] }
    func settings() async throws -> HoldSettings { saved }

    func setGreeting(_ greeting: HoldGreeting) async throws -> HoldSettings {
        await record("holdForMe.greeting:\(greeting.rawValue)")
        return HoldSettings(greeting: greeting, assistantAvailable: saved.assistantAvailable, maxWaitSecs: saved.maxWaitSecs)
    }
}

/// Live Activities held in memory: fixtures never reach ActivityKit.
@MainActor
final class FixtureActivityFacade: ActivityFacade {
    private var live: Set<String> = []
    func existingIds() -> [String] { Array(live) }
    func start(_ attributes: HoldWaitAttributes, state: HoldWaitAttributes.ContentState, staleDate: Date) {
        live.insert(attributes.holdWaitId)
    }
    func update(id: String, state: HoldWaitAttributes.ContentState, staleDate: Date) {}
    func end(id: String) { live.remove(id) }
}

// MARK: - Voicemail

/// In-memory mailbox. Audio is a generated silent WAV of the message's
/// length, so the real player runs and shows progress.
final class FixtureVoicemailBackend: VoicemailBackend {
    private var stored: [VoicemailService.Message]?

    init(messages: [VoicemailService.Message]? = FixtureData.voicemail()) {
        stored = messages
    }

    func messages() async throws -> [VoicemailService.Message]? { stored }

    func markRead(messageId: String) async throws {
        guard let index = stored?.firstIndex(where: { $0.id == messageId }) else { return }
        stored?[index].read = true
    }

    func delete(messageId: String) async throws {
        stored?.removeAll { $0.id == messageId }
    }

    func audioFile(messageId: String) async throws -> URL {
        let seconds = stored?.first { $0.id == messageId }?.durationSecs ?? 10
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-vm-\(messageId)-\(UUID().uuidString).wav")
        try Self.silentWav(seconds: seconds).write(to: url)
        return url
    }

    func reset() {}

    /// 8 kHz 16-bit mono PCM silence.
    static func silentWav(seconds: Int, sampleRate: Int = 8000) -> Data {
        let dataSize = UInt32(max(1, seconds) * sampleRate * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
#endif
