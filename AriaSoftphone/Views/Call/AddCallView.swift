import SwiftUI

/// Place a second call while one is up: pick a number (typed or from
/// Contacts). The call in progress is put on hold while the new one rings.
struct AddCallView: View {
    @EnvironmentObject var callManager: CallManager
    @Environment(\.dismiss) private var dismiss

    @State private var number = ""
    @State private var errorMessage: String?
    @State private var showContactPicker = false
    @FocusState private var fieldFocused: Bool

    private var trimmedNumber: String {
        number.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Number or extension", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(.title3)
                        .focused($fieldFocused)

                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Choose from Contacts", systemImage: "person.crop.circle")
                    }
                } footer: {
                    Text("\(callManager.activeCall?.displayName ?? "Your current call") will be put on hold while you make this call.")
                }

                if let errorMessage = errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Add Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Call", action: call)
                        .disabled(trimmedNumber.isEmpty || !callManager.canAddCall)
                }
            }
            .sheet(isPresented: $showContactPicker) {
                ContactPhonePicker { picked in
                    // Contacts store numbers formatted for reading.
                    number = picked.filter { !" ()-.\u{00A0}".contains($0) }
                    errorMessage = nil
                }
                .ignoresSafeArea()
            }
            .onAppear { fieldFocused = true }
            .onChange(of: callManager.activeCall == nil) { callsEnded in
                if callsEnded { dismiss() }
            }
        }
    }

    private func call() {
        guard TransferError.isAcceptableTarget(trimmedNumber) else {
            errorMessage = "That number can't be called. Check it and try again."
            return
        }
        callManager.startOutgoingCall(uri: trimmedNumber)
        dismiss()
    }
}
