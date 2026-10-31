import SwiftUI

struct AccountsCard: View {
    let studio: StudioModel
    @State private var showingAdd = false

    var body: some View {
        SectionCard("Accounts", systemImage: "person.2") {
            Button("Add account…") { showingAdd = true }
                .disabled(studio.cliPath == nil)
        } content: {
            if studio.cliPath == nil {
                Text("Install the claude CLI to manage accounts.").foregroundStyle(.secondary)
            } else {
                ForEach(studio.profiles.profiles) { profile in
                    AccountRow(
                        profile: profile,
                        state: studio.account(for: profile),
                        isActive: profile.id == studio.profiles.activeID
                    ) { studio.select(profile) }
                    if profile.id != studio.profiles.profiles.last?.id { Divider() }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddAccountSheet(studio: studio, isPresented: $showingAdd)
        }
    }
}

private struct AccountRow: View {
    let profile: Profile
    let state: AccountState
    let isActive: Bool
    let onUse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).fontWeight(.semibold)
                detail
            }
            Spacer(minLength: 8)
            trailing
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .signedIn(let status):
            VStack(alignment: .leading, spacing: 2) {
                if let email = status.email { Text(email).textSelection(.enabled) }
                Text(subtitle(status)).font(.caption).foregroundStyle(.secondary)
            }
        case .signedOut:
            VStack(alignment: .leading, spacing: 4) {
                Text("Not signed in").foregroundStyle(.secondary)
                Text(profile.loginCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isActive {
            Text("Active")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        } else if case .signedIn = state {
            Button("Use", action: onUse)
        }
    }

    private func subtitle(_ status: ClaudeAuthStatus) -> String {
        [status.orgName, status.subscriptionType?.capitalized, status.authMethod]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct AddAccountSheet: View {
    let studio: StudioModel
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var email = ""
    @State private var code = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { studio.profiles.isNameTaken(trimmedName) }
    private var inProgress: Bool { studio.login == .running || studio.login == .verifying }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add account").font(.title2.bold())

            if inProgress {
                progress
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(inProgress)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").foregroundStyle(.secondary)
                TextField("e.g. Personal", text: $name).textFieldStyle(.roundedBorder)
                if nameTaken {
                    Text("You already have an account with that name.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Email (optional)").foregroundStyle(.secondary)
                TextField("Pre-fills the sign-in page", text: $email).textFieldStyle(.roundedBorder)
            }
            Text("Logging in opens your browser. Sign in with the account you want to add.")
                .font(.caption).foregroundStyle(.secondary)

            if case .failed(let message) = studio.login {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    studio.clearLoginError()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Log in") { startLogin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || nameTaken)
            }
        }
    }

    private func startLogin() {
        Task {
            await studio.addAccount(name: trimmedName, email: email)
            if studio.login == .idle { isPresented = false }
        }
    }

    // MARK: Waiting for the browser

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(studio.login == .verifying
                     ? "Checking the account…"
                     : "Finish signing in in your browser…")
            }

            if studio.login == .running {
                if let url = studio.loginURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Browser didn't open, or it signs in as the wrong account?")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Copy sign-in link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                            Text("Paste it into a private window.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("If the browser shows a code, paste it here:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Code", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submitCode)
                        Button("Submit", action: submitCode)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel sign-in") { studio.cancelLogin() }
                }
            }
        }
    }

    private func submitCode() {
        studio.submitLoginCode(code)
        code = ""
    }
}
