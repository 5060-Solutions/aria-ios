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
    /// Ask for (or confirm) access; false when the user has refused it.
    func requestAccess() async throws -> Bool
    /// Every contact with a phone number, sorted by given name.
    func fetchContacts() throws -> [ContactEntry]
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
