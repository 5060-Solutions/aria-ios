import SwiftUI
import ContactsUI

/// Transfer the call `callUUID`: pick a number (typed or from Contacts), then
/// either hand the call over to it at once (blind), or call it first to
/// introduce the caller (consult), holding this call, and complete the
/// transfer from the call screen.
struct TransferView: View {
    let callUUID: UUID
    let callerName: String

    @EnvironmentObject var callManager: CallManager
    @Environment(\.dismiss) private var dismiss

    @State private var target = ""
    @State private var isTransferring = false
    @State private var errorMessage: String?

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            CallTargetForm(
                number: $target,
                explanation: Text("Transfer connects \(callerName) to this number and ends your call. Consult first to speak to them before you hand over."),
                errorMessage: errorMessage,
                isDisabled: isTransferring
            ) {
                AriaButton(isTransferring ? "Transferring…" : "Transfer Now", systemImage: "phone.arrow.right",
                           kind: .prominent, size: .primary, fullWidth: true, isLoading: isTransferring,
                           action: transfer)
                    .disabled(trimmedTarget.isEmpty)
                AriaButton("Consult First", systemImage: "phone.arrow.up.right", kind: .standard,
                           size: .primary, fullWidth: true, action: consult)
                    .disabled(trimmedTarget.isEmpty || isTransferring || !callManager.canAddCall)
                if isTransferring {
                    // The core waits for the PBX to report the outcome.
                    Text("This can take up to 45 seconds.")
                        .ariaFont(.bodySmall)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                }
            }
            .navigationTitle("Transfer \(callerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .disabled(isTransferring)
                }
            }
            .interactiveDismissDisabled(isTransferring)
            .onChange(of: callManager.registry[callUUID] == nil) { _, callEnded in
                // The transfer went through (or the call ended some other way).
                if callEnded { dismiss() }
            }
        }
        .presentationDetents([.large])
    }

    private func transfer() {
        guard !trimmedTarget.isEmpty, !isTransferring else { return }
        isTransferring = true
        errorMessage = nil

        callManager.transferCall(uuid: callUUID, to: trimmedTarget) { error in
            isTransferring = false
            if let error = error {
                errorMessage = error.localizedDescription
            } else {
                dismiss()
            }
        }
    }

    /// Call the target while this call holds; "Complete Transfer" then
    /// appears on the call screen once the target answers.
    private func consult() {
        guard TransferError.isAcceptableTarget(trimmedTarget) else {
            errorMessage = TransferError.invalidTarget.localizedDescription
            return
        }
        callManager.startOutgoingCall(uri: trimmedTarget)
        dismiss()
    }
}

// MARK: - Contact Picker

/// The system contact picker, limited to phone numbers. Runs out of process,
/// so it needs no Contacts permission.
struct ContactPhonePicker: UIViewControllerRepresentable {
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
