import SwiftUI

/// The shared body of the Transfer and Add Call sheets: a number field in
/// the display style, Choose from Contacts, an explanation, an error, and
/// the sheet's actions underneath.
struct CallTargetForm<Actions: View>: View {
    @Binding var number: String
    let explanation: Text
    var errorMessage: String?
    var isDisabled = false
    @ViewBuilder var actions: () -> Actions

    @State private var showContactPicker = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                TextField("Number or extension", text: $number)
                    .ariaFont(.title)
                    .multilineTextAlignment(.center)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($fieldFocused)
                    .disabled(isDisabled)
                    .ariaField()
                    .accessibilityLabel(Text("Number or extension"))

                AriaButton("Choose from Contacts", systemImage: "person.crop.circle", kind: .standard,
                           fullWidth: true) {
                    showContactPicker = true
                }
                .disabled(isDisabled)

                explanation
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let errorMessage {
                    Banner(message: .error(errorMessage))
                }

                VStack(spacing: Space.s) {
                    actions()
                }
                .padding(.top, Space.xs)
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AriaColor.background)
        .sheet(isPresented: $showContactPicker) {
            ContactPhonePicker { picked in
                // Contacts store numbers formatted for reading.
                number = picked.filter { !" ()-.\u{00A0}".contains($0) }
            }
            .ignoresSafeArea()
        }
        .onAppear { fieldFocused = true }
    }
}
