import SwiftUI
import tetmuxCore

/// Answers an ssh prompt that could not be filled from the Keychain.
///
/// The prompt text is shown verbatim (§7) rather than rewritten as "Enter password for host". ssh's
/// wording names the account and the host it is really asking about, which is the only way to tell
/// which hop of a `ProxyJump` chain — or which key — is being asked for.
struct AuthenticationSheet: View {
    let pending: AppModel.PendingAuthentication
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var secret = ""
    @State private var save = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: pending.prompt.kind == .password ? "lock.fill" : "key.fill")
                    .foregroundStyle(.secondary)
                Text(pending.hostName).font(.headline)
            }

            Text(pending.prompt.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("", text: $secret)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($isFieldFocused)
                .onSubmit { submit() }

            if pending.canOfferKeychain {
                Toggle("Save in the login Keychain", isOn: $save)
                    .font(.callout)
            } else {
                // A key's passphrase is a property of the key. Storing it per host would put it under
                // the wrong identity and reuse it for the wrong key as soon as either changed —
                // ssh-agent is the right place for it, and it already handles this.
                Text("Key passphrases are not stored — add the key to your ssh agent to avoid this prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFieldFocused = true }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        onSubmit(secret, save && pending.canOfferKeychain)
    }
}
