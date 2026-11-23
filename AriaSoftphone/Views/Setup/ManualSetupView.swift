import SwiftUI

/// Sign in by typing the account in: tenant domain, extension, password,
/// and optionally the SIP server and PBX API address. Validated before
/// anything is stored; sign-in then goes through `AccountSession.login`, as
/// after a QR scan.
struct ManualSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = AccountSession.shared

    @State private var form = ManualSetup()
    /// Problems are shown once the user has tried to continue, not while
    /// they are still typing the first field.
    @State private var showProblems = false
    @State private var showAdvanced = false
    @FocusState private var focused: ManualSetup.Field?

    private var problems: [ManualSetup.Field: ManualSetup.Problem] {
        showProblems ? form.problems() : [:]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(.domain, "Tenant domain", text: $form.domain, prompt: "acme.ariaroute.com",
                          content: .URL, keyboard: .URL)
                    field(.extensionNumber, "Extension", text: $form.extensionNumber, prompt: "1001",
                          content: .username, keyboard: .asciiCapable)
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("Password", text: $form.password)
                            .textContentType(.password)
                            .focused($focused, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("manualSetup.password")
                        problemText(.password)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Your administrator can give you these details. The password is your extension's SIP password.")
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        field(.server, "SIP server", text: $form.server, prompt: "Same as tenant domain",
                              content: .URL, keyboard: .URL)
                        field(.apiUrl, "API address", text: $form.apiUrl, prompt: ManualSetup.defaultApiUrl,
                              content: .URL, keyboard: .URL)
                    }
                    .accessibilityIdentifier("manualSetup.advanced")
                } footer: {
                    Text("The API address must use HTTPS. Leave these empty unless your administrator gave you different values.")
                }

                if let message = session.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("manualSetup.error")
                    }
                }
            }
            .navigationTitle("Enter Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if session.isConnecting {
                        ProgressView()
                    } else {
                        Button("Sign In", action: submit)
                            .accessibilityIdentifier("manualSetup.signIn")
                    }
                }
            }
        }
    }

    private func submit() {
        showProblems = true
        let found = form.problems()
        guard found.isEmpty, let credentials = form.credentials() else {
            focused = ManualSetup.Field.allCases.first { found[$0] != nil }
            if found[.server] != nil || found[.apiUrl] != nil { showAdvanced = true }
            return
        }
        AccountSession.shared.applyProvisioning(credentials)
        AccountSession.shared.login()
        dismiss()
    }

    private func field(
        _ field: ManualSetup.Field,
        _ title: LocalizedStringKey,
        text: Binding<String>,
        prompt: String,
        content: UITextContentType,
        keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text, prompt: Text(prompt))
                .textContentType(content)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .submitLabel(.next)
                .accessibilityIdentifier("manualSetup.\(Self.identifier(field))")
            problemText(field)
        }
    }

    @ViewBuilder
    private func problemText(_ field: ManualSetup.Field) -> some View {
        if let problem = problems[field] {
            Text(problem.message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("manualSetup.\(Self.identifier(field)).problem")
        }
    }

    static func identifier(_ field: ManualSetup.Field) -> String {
        switch field {
        case .domain: return "domain"
        case .server: return "server"
        case .extensionNumber: return "extension"
        case .password: return "password"
        case .apiUrl: return "apiUrl"
        }
    }
}
