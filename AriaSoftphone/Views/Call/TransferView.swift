import SwiftUI
import ContactsUI

/// Blind transfer: pick a number (typed or from Contacts) and hand the call
/// over to it.
struct TransferView: View {
    @EnvironmentObject var callManager: CallManager
    @Environment(\.dismiss) private var dismiss

    @State private var target = ""
    @State private var isTransferring = false
    @State private var errorMessage: String?
    @State private var showContactPicker = false
    @FocusState private var fieldFocused: Bool

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Number or extension", text: $target)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(.title3)
                        .focused($fieldFocused)
                        .disabled(isTransferring)

                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Choose from Contacts", systemImage: "person.crop.circle")
                    }
                    .disabled(isTransferring)
                } footer: {
                    Text("\(callManager.activeCall?.displayName ?? "The caller") will be connected to this number and your call will end.")
                }

                if let errorMessage = errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Transfer Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isTransferring)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isTransferring {
                        ProgressView()
                    } else {
                        Button("Transfer", action: transfer)
                            .disabled(trimmedTarget.isEmpty)
                    }
                }
            }
            .overlay {
                if isTransferring {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Transferring...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .interactiveDismissDisabled(isTransferring)
            .sheet(isPresented: $showContactPicker) {
                ContactPhonePicker { number in
                    // Contacts store numbers formatted for reading.
                    target = number.filter { !" ()-.\u{00A0}".contains($0) }
                    errorMessage = nil
                }
                .ignoresSafeArea()
            }
            .onAppear { fieldFocused = true }
            .onChange(of: callManager.activeCall == nil) { callEnded in
                // The transfer went through (or the call ended some other way).
                if callEnded { dismiss() }
            }
        }
    }

    private func transfer() {
        guard !trimmedTarget.isEmpty, !isTransferring else { return }
        isTransferring = true
        errorMessage = nil
        fieldFocused = false

        callManager.transferCall(to: trimmedTarget) { error in
            isTransferring = false
            if let error = error {
                errorMessage = error.localizedDescription
            } else {
                dismiss()
            }
        }
    }
}

// MARK: - Contact Picker

/// The system contact picker, limited to phone numbers. Runs out of process,
/// so it needs no Contacts permission.
private struct ContactPhonePicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        // Tapping a contact with one number picks it; with several, the
        // picker shows them.
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String) -> Void

        init(onPick: @escaping (String) -> Void) {
            self.onPick = onPick
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let number = contact.phoneNumbers.first?.value.stringValue {
                onPick(number)
            }
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            if let number = (contactProperty.value as? CNPhoneNumber)?.stringValue {
                onPick(number)
            }
        }
    }
}
