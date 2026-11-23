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
        AccountSession.shared.applyFixture(signedIn: scene.isSignedIn)
        CallManager.shared.loadFixture(calls: FixtureData.calls(for: scene))
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
