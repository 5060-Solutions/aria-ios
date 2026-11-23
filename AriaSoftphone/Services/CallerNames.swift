import Foundation
import Contacts

/// Names for numbers, from the address book, for incoming calls and
/// history. Built off the main thread into a small index so CallKit can be
/// given a name synchronously when a push arrives.
///
/// Only used once the user has granted Contacts access (the Contacts tab
/// asks); this never prompts.
final class CallerNames {
    static let shared = CallerNames(source: ContactsSources.current, isAuthorized: {
        #if DEBUG
        if FixtureMode.isActive { return true }
        #endif
        return CNContactStore.authorizationStatus(for: .contacts) == .authorized
    })

    private let source: ContactsSource
    private let isAuthorized: () -> Bool
    private let lock = NSLock()
    private var index: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.5060.aria.caller-names", qos: .utility)

    init(source: ContactsSource, isAuthorized: @escaping () -> Bool) {
        self.source = source
        self.isAuthorized = isAuthorized
    }

    /// Rebuild the index in the background (launch, foreground).
    func reload(completion: (() -> Void)? = nil) {
        queue.async {
            self.reloadNow()
            completion?()
        }
    }

    func reloadNow() {
        guard isAuthorized(), let contacts = try? source.fetchContacts() else { return }
        var built: [String: String] = [:]
        for contact in contacts where !contact.name.isEmpty {
            for number in contact.phoneNumbers {
                for key in Self.keys(number) where built[key] == nil {
                    built[key] = contact.name
                }
            }
        }
        lock.lock()
        index = built
        lock.unlock()
    }

    /// The contact name for a number or SIP URI, if there is one.
    func name(for uri: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        for key in Self.keys(uri) {
            if let name = index[key] { return name }
        }
        return nil
    }

    /// `name` unless `current` is already a real name (not empty, not just
    /// the number).
    func resolve(uri: String, current: String?) -> String? {
        if let current = current, !current.isEmpty, current != uri,
           current != CallRecord.userPart(uri) {
            return current
        }
        return name(for: uri) ?? current
    }

    /// Lookup keys: the last ten digits of a phone number (so `+1 555…` and
    /// `555…` meet), or the whole digit string for short extensions.
    static func keys(_ value: String) -> [String] {
        let digits = CallRecord.userPart(value).filter(\.isNumber)
        guard !digits.isEmpty else { return [] }
        return digits.count >= 7 ? [String(digits.suffix(10))] : [digits]
    }
}
