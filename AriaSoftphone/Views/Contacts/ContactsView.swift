import SwiftUI
import Contacts

/// Contacts view with system contacts integration.
struct ContactsView: View {
    @EnvironmentObject var callManager: CallManager
    @State private var contacts: [ContactEntry] = []
    @State private var searchText = ""
    @State private var hasPermission = false

    var filteredContacts: [ContactEntry] {
        if searchText.isEmpty { return contacts }
        return contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(searchText) ||
            contact.phoneNumbers.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasPermission {
                    ContentUnavailableView(
                        "No Access",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Grant Contacts access in Settings to see your contacts here.")
                    )
                } else if contacts.isEmpty {
                    ContentUnavailableView(
                        "No Contacts",
                        systemImage: "person.crop.circle",
                        description: Text("Your contacts will appear here.")
                    )
                } else {
                    List(filteredContacts) { contact in
                        ContactRow(contact: contact) { number in
                            callManager.startOutgoingCall(uri: number)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search contacts")
                }
            }
            .navigationTitle("Contacts")
            .task { await loadContacts() }
        }
    }

    private func loadContacts() async {
        let store = CNContactStore()

        do {
            let granted = try await store.requestAccess(for: .contacts)
            hasPermission = granted
            guard granted else { return }

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

            await MainActor.run {
                contacts = fetched
            }
        } catch {
            print("Failed to load contacts: \(error)")
        }
    }
}

// MARK: - Contact Model

struct ContactEntry: Identifiable {
    let id = UUID()
    let name: String
    let phoneNumbers: [String]
    let hasImage: Bool
    let thumbnailData: Data?
}

// MARK: - Contact Row

struct ContactRow: View {
    let contact: ContactEntry
    let onCall: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            if let data = contact.thumbnailData,
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(contact.name.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundColor(.secondary)
                    )
            }

            // Name and numbers
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.name)
                    .font(.body)

                if let firstNumber = contact.phoneNumbers.first {
                    Text(firstNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Call button
            if let number = contact.phoneNumbers.first {
                Button(action: { onCall(number) }) {
                    Image(systemName: "phone.fill")
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
