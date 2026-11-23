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
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let message = session.errorMessage {
                        Banner(message: .error(message))
                            .accessibilityIdentifier("manualSetup.error")
                    }

                    SectionCard(
                        title: Text("Account"),
                        footer: Text("Your administrator can give you these details. The password is your extension's SIP password.")
                    ) {
                        textField(.domain, "Tenant domain", text: $form.domain, prompt: "acme.ariaroute.com",
                                  content: .URL, keyboard: .URL)
                        textField(.extensionNumber, "Extension", text: $form.extensionNumber, prompt: "1001",
                                  content: .username, keyboard: .asciiCapable)
                        FieldBlock(label: "Password", problem: problems[.password]?.message,
                                   problemIdentifier: "manualSetup.password.problem") {
                            SecureField("Password", text: $form.password)
                                .textContentType(.password)
                                .focused($focused, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(submit)
                                .ariaField(invalid: problems[.password] != nil)
                                .accessibilityIdentifier("manualSetup.password")
                        }
                    }

                    SectionCard(
                        footer: Text("The API address must use HTTPS. Leave these empty unless your administrator gave you different values.")
                    ) {
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            textField(.server, "SIP server", text: $form.server, prompt: String(localized: "Same as tenant domain"),
                                      content: .URL, keyboard: .URL)
                            textField(.apiUrl, "API address", text: $form.apiUrl, prompt: ManualSetup.defaultApiUrl,
                                      content: .URL, keyboard: .URL)
                        } label: {
                            Text("Advanced")
                                .ariaFont(.body)
                                .foregroundStyle(AriaColor.onSurface)
                                .frame(minHeight: ComponentSize.row)
                        }
                        .tint(AriaColor.primary)
                        .accessibilityIdentifier("manualSetup.advanced")
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.m)
            }
            .background(AriaColor.background)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                AriaButton("Sign In", kind: .prominent, size: .primary, fullWidth: true,
                           isLoading: session.isConnecting, action: submit)
                    .accessibilityIdentifier("manualSetup.signIn")
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.bottom, Space.xs)
            }
            .navigationTitle("Enter Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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

    private func textField(
        _ field: ManualSetup.Field,
        _ title: LocalizedStringKey,
        text: Binding<String>,
        prompt: String,
        content: UITextContentType,
        keyboard: UIKeyboardType
    ) -> some View {
        let id = Self.identifier(field)
        return FieldBlock(label: title, problem: problems[field]?.message,
                          problemIdentifier: "manualSetup.\(id).problem") {
            TextField(title, text: text, prompt: Text(prompt))
                .textContentType(content)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .submitLabel(.next)
                .ariaField(invalid: problems[field] != nil)
                .accessibilityIdentifier("manualSetup.\(id)")
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
