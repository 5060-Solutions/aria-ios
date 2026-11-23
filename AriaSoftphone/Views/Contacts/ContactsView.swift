import SwiftUI

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
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Access")
                            .font(.headline)
                        Text("Grant Contacts access in Settings to see your contacts here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Contacts")
                            .font(.headline)
                        Text("Your contacts will appear here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
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
        let source = ContactsSources.current
        do {
            let granted = try await source.requestAccess()
            hasPermission = granted
            guard granted else { return }
            let fetched = try source.fetchContacts()
            await MainActor.run {
                contacts = fetched
            }
        } catch {
            print("Failed to load contacts: \(error)")
        }
    }
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
