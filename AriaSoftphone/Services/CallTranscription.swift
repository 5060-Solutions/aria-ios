import Foundation
import Security

/// Drives on-device transcription across a call's lifetime.
///
/// Capture is opt-in and off by default. Tapping call audio is a recording, so
/// the decision belongs to the user rather than to whether a model happens to
/// be installed — `isEnabled` gates every entry point here, and a device with a
/// model downloaded but the toggle off captures nothing.
///
/// Audio never crosses the FFI boundary: the tap lives in the Rust media layer,
/// and this type only passes call ids in and reads finished text back out.
final class CallTranscription {
    static let shared = CallTranscription()
    private init() {}

    private let enabledKey = "ai_transcribe_calls"
    private let keychainAccount = "ai_insight_key"

    /// Call ids captured this session, so a stop can never run without a start.
    private var capturing = Set<String>()
    private let queue = DispatchQueue(label: "com.5060.aria.transcription")

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// True when this build has the models compiled in.
    ///
    /// The simulator slice is built without them — a 600 MB model on a
    /// simulator is not useful — so this is false there and true on device.
    var isAvailable: Bool {
        SipEngineManager.shared.aiAvailable()
    }

    // MARK: - Key custody

    /// The key transcripts are encrypted with at rest, created on first use.
    ///
    /// It lives in the keychain with `ThisDeviceOnly` accessibility, so it is
    /// not carried to another device by a backup. The Rust side never generates
    /// or stores a key — losing this one means the stored transcripts are gone,
    /// which is the intended failure mode for call recordings.
    private func insightKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == 32 {
            return data
        }

        var fresh = Data(count: 32)
        let ok = fresh.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base) == errSecSuccess
        }
        guard ok else { return nil }

        // Delete first: a malformed leftover would make the add fail as a
        // duplicate and leave us with no usable key.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: fresh,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return fresh
    }

    /// Where models and the insight database live. Application Support is
    /// excluded from iCloud backup for this kind of data and cleared on delete.
    private func storageDir() -> String? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent("ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - Lifecycle

    /// Bring up the AI engine with encrypted transcript storage.
    ///
    /// Safe to call repeatedly: both the model screen and the call path need it
    /// initialised, and neither knows which ran first.
    func initialise() throws {
        let manager = SipEngineManager.shared
        guard manager.aiAvailable(), let dir = storageDir() else { return }
        try manager.aiInit(storageDir: dir, insightKey: insightKey().map { [UInt8]($0) })
    }

    /// True when a speech model is installed and this build can use it.
    func isReady() -> Bool {
        let manager = SipEngineManager.shared
        guard manager.aiAvailable() else { return false }
        do {
            try initialise()
            return manager.aiModels().contains { $0.kind == "stt" && $0.installed }
        } catch {
            print("AI readiness probe failed: \(error)")
            return false
        }
    }

    /// Begin capturing, if the user asked for it and a model is actually there.
    ///
    /// Every failure path here is non-fatal: a call must connect whether or not
    /// transcription can run.
    func onCallStarted(callId: String) {
        guard isEnabled else { return }
        queue.async {
            guard !self.capturing.contains(callId) else { return }
            guard self.isReady() else {
                print("Transcription on but no speech model installed; skipping \(callId)")
                return
            }
            do {
                try SipEngineManager.shared.aiStartCapture(callId: callId)
                self.capturing.insert(callId)
                print("Capturing audio for \(callId)")
            } catch {
                print("Could not start capture for \(callId): \(error)")
            }
        }
    }

    /// Stop capturing and transcribe, handing the result back on the main queue.
    ///
    /// Transcription is far slower than the call teardown it follows, so it
    /// runs on this type's own queue rather than blocking the caller.
    func onCallEnded(callId: String, completion: ((AiCallInsight?) -> Void)? = nil) {
        queue.async {
            guard self.capturing.remove(callId) != nil else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            let manager = SipEngineManager.shared
            var result: AiCallInsight?
            do {
                manager.aiStopCapture(callId: callId)
                result = try manager.aiTranscribe(callId: callId)
            } catch {
                print("Transcription failed for \(callId): \(error)")
                // Drop the audio rather than leaving it on disk after a failure.
                manager.aiDiscardCapture(callId: callId)
            }
            let insight = result
            DispatchQueue.main.async { completion?(insight) }
        }
    }

    /// Throw away captured audio without transcribing it.
    func discard(callId: String) {
        queue.async {
            guard self.capturing.remove(callId) != nil else { return }
            SipEngineManager.shared.aiDiscardCapture(callId: callId)
        }
    }
}
