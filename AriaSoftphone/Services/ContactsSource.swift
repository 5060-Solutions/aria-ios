import Foundation
import Contacts

/// One address-book contact with at least one phone number.
struct ContactEntry: Identifiable {
    let id = UUID()
    let name: String
    let phoneNumbers: [String]
    let hasImage: Bool
    let thumbnailData: Data?
    var isFavorite: Bool = false
}

/// Where the Contacts tab gets its contacts. Live: the system address book.
/// Fixture mode swaps in canned contacts (see `FixtureBackends.swift`).
protocol ContactsSource {
    /// Whether access is already granted, without asking.
    var isAuthorized: Bool { get }
    /// Ask for (or confirm) access; false when the user has refused it.
    func requestAccess() async throws -> Bool
    /// Every contact with a phone number, sorted by given name.
    func fetchContacts() throws -> [ContactEntry]
}

extension ContactsSource {
    /// Sources without a permission model (test fakes) are always readable.
    var isAuthorized: Bool { true }
}

enum ContactsSources {
    /// The source the app uses: fixtures in fixture mode, else the system's.
    static var current: ContactsSource {
        #if DEBUG
        if FixtureMode.isActive { return FixtureContactsSource() }
        #endif
        return SystemContactsSource()
    }
}

/// The system address book.
struct SystemContactsSource: ContactsSource {
    private let store = CNContactStore()

    var isAuthorized: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    func fetchContacts() throws -> [ContactEntry] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var fetched: [ContactEntry] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let numbers = contact.phoneNumbers.map { $0.value.stringValue }
            guard !numbers.isEmpty else { return }

            fetched.append(ContactEntry(
                name: "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
                phoneNumbers: numbers,
                hasImage: contact.imageDataAvailable,
                thumbnailData: contact.thumbnailImageData
            ))
        }
        return fetched
    }
}

/// The address book, loaded once for screens that only look names up (the
/// dialer's match line). Never asks for access: it loads only when access
/// has already been granted, and again once the Contacts tab is granted it.
@MainActor
final class ContactDirectory: ObservableObject {
    static let shared = ContactDirectory(source: ContactsSources.current)

    @Published private(set) var contacts: [ContactEntry] = []
    private let source: ContactsSource
    private var loaded = false

    init(source: ContactsSource) {
        self.source = source
    }

    func loadIfAuthorized() async {
        guard !loaded, source.isAuthorized else { return }
        loaded = true
        let source = self.source
        let fetched = await Task.detached { (try? source.fetchContacts()) ?? [] }.value
        contacts = fetched
    }

    /// Use contacts another screen has just fetched.
    func update(_ contacts: [ContactEntry]) {
        loaded = true
        self.contacts = contacts
    }
}
