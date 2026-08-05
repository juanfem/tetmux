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

            // A host-key question is meaningless without the fingerprint, which ssh puts on a
            // *different* line — so the lines leading up to it are shown too, verbatim and
            // selectable, because a fingerprint nobody can copy is a fingerprint nobody can check.
            Text(pending.prompt.context ?? pending.prompt.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if pending.prompt.answerIsSecret {
                SecureField("", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .focused($isFieldFocused)
                    .onSubmit { submit() }
            }

            if pending.prompt.kind == .hostKey {
                // tetmux does not decide this, and does not remember it either: answering `yes` is
                // what makes *ssh* write the key to `known_hosts`, exactly as it would from a
                // terminal. §2.3 forbids the application accepting a key on the user's behalf, which
                // is why there is no "always trust" here and why Cancel is the default button.
                Text("Only continue if that fingerprint is the one you expect. tetmux does not verify it, and answering here is the same as answering ssh in a terminal — it is your ssh client that will remember the key, not tetmux.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pending.canOfferKeychain {
                Toggle("Save in the login Keychain", isOn: $save)
                    .font(.callout)
            } else if pending.prompt.kind == .keyPassphrase {
                // A key's passphrase is a property of the key. Storing it per host would put it under
                // the wrong identity and reuse it for the wrong key as soon as either changed —
                // ssh-agent is the right place for it, and it already handles this.
                Text("Key passphrases are not stored — add the key to your ssh agent to avoid this prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // An unclassified question is most often a second factor, and a one-time code is
                // worth nothing tomorrow. Nothing here offers to keep it.
                Text("tetmux does not recognise this prompt, so it is shown exactly as ssh asked it. The answer is sent and not stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // Cancel keeps the default on a host-key question: the safe answer to "do you trust
                // this key" is the one that does not, and Return is not a decision anybody made.
                Button(pending.prompt.kind == .hostKey ? "Continue Connecting" : "Continue", action: submit)
                    .keyboardShortcut(pending.prompt.kind == .hostKey ? .init(.end) : .defaultAction)
                    .disabled(pending.prompt.answerIsSecret && secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFieldFocused = pending.prompt.answerIsSecret }
    }

    private func submit() {
        // ssh accepts `yes`, `no`, or the fingerprint. "Continue Connecting" is the user saying the
        // first of those; the wording of the button is ours, the word on the wire is ssh's.
        if pending.prompt.kind == .hostKey {
            onSubmit("yes", false)
            return
        }
        guard !secret.isEmpty else { return }
        onSubmit(secret, save && pending.canOfferKeychain)
    }
}
