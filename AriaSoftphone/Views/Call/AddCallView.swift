import SwiftUI

/// Place a second call while one is up: pick a number (typed or from
/// Contacts). The call in progress is put on hold while the new one rings.
struct AddCallView: View {
    @EnvironmentObject var callManager: CallManager
    @Environment(\.dismiss) private var dismiss

    @State private var number = ""
    @State private var errorMessage: String?

    private var trimmedNumber: String {
        number.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            CallTargetForm(
                number: $number,
                explanation: Text("\(callManager.activeCall?.displayName ?? String(localized: "Your current call")) will be put on hold while you make this call."),
                errorMessage: errorMessage
            ) {
                AriaButton("Call", systemImage: "phone.fill", kind: .prominent, size: .primary,
                           fullWidth: true, action: call)
                    .disabled(trimmedNumber.isEmpty || !callManager.canAddCall)
            }
            .navigationTitle("Add Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .onChange(of: callManager.activeCall == nil) { _, callsEnded in
                if callsEnded { dismiss() }
            }
        }
        .presentationDetents([.large])
    }

    private func call() {
        guard TransferError.isAcceptableTarget(trimmedNumber) else {
            errorMessage = String(localized: "That number can't be called. Check it and try again.")
            return
        }
        switch callManager.startOutgoingCall(uri: trimmedNumber) {
        case .placed, .emergencyHandoff:
            dismiss()
        case .refused:
            errorMessage = String(localized: "Can't place another call right now.")
        }
    }
}
