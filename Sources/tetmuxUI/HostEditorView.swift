import SwiftUI
import tetmuxCore

/// Add or edit an ssh host: the destination, how it authenticates, and any forwards its channel
/// should carry.
///
/// The password field is write-only. It is never populated from the Keychain, because showing a
/// stored secret back to whoever opens the editor is a worse trade than making them retype it, and an
/// empty field on an existing host means "leave the stored one alone" rather than "clear it".
struct HostEditorView: View {
    let draft: AppModel.HostDraft
    let onSave: (AppModel.HostDraft, String?, Bool) -> Void
    let onCancel: () -> Void

    @State private var host: StoredHost
    @State private var portText: String
    @State private var password: String = ""
    @State private var savePassword: Bool
    /// `ssh -G`'s answer for whatever is currently in the Host field (F4.2). Empty until it arrives,
    /// and empty for a name ssh cannot make sense of, so every read of it has a fallback.
    @State private var resolved: [String: String] = [:]

    init(
        draft: AppModel.HostDraft,
        onSave: @escaping (AppModel.HostDraft, String?, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        self._host = State(initialValue: draft.host)
        self._portText = State(initialValue: draft.host.port.map(String.init) ?? "")
        self._savePassword = State(initialValue: draft.host.storesPasswordInKeychain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.isNew ? "Add SSH Host" : "Edit \(draft.host.name)")
                .font(.headline)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    destinationSection
                    Divider()
                    authenticationSection
                    Divider()
                    forwardsSection
                    Divider()
                    sshOptionsSection
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 460)

            Divider().padding(.vertical, 12)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Host" : "Save") {
                    var edited = draft
                    edited.host = host
                    edited.host.port = Int(portText.trimmingCharacters(in: .whitespaces))
                    onSave(edited, password.isEmpty ? nil : password, savePassword)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination").font(.subheadline).fontWeight(.semibold)
            Text("The name is passed straight to `ssh`, so any alias from your ~/.ssh/config works — including ProxyJump and Match rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Host").gridColumnAlignment(.trailing)
                    TextField("devbox or 192.168.1.50", text: $host.name).frame(width: 300)
                }
                GridRow {
                    Text("User").gridColumnAlignment(.trailing)
                    // The placeholder is what ssh will use if this is left blank, not a generic
                    // "optional" — see `resolveEffectiveConfig`.
                    TextField(
                        resolved["user"] ?? "optional",
                        text: Binding($host.user, replacingNilWith: "")
                    )
                    .frame(width: 300)
                }
                GridRow {
                    Text("Port").gridColumnAlignment(.trailing)
                    TextField(resolved["port"] ?? "22", text: $portText).frame(width: 90)
                }
            }
            .textFieldStyle(.roundedBorder)

            if let summary = resolvedSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Here rather than behind a dialog at creation time, which is the whole reason it can
            // exist: New Session deliberately puts nothing between wanting a shell and having one,
            // and where a session starts is a thing you decide once per machine anyway. tmux resolves
            // the path on the far side, so `~` and a directory that only exists on the remote both
            // work — and there is no folder picker for the same reason.
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Start in").gridColumnAlignment(.trailing)
                    TextField(
                        "~/projects — optional",
                        text: Binding($host.startDirectory, replacingNilWith: "")
                    )
                    .frame(width: 300)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)

            Text("Where a new session's first pane opens, as `new-session -c`. Resolved on \(host.name.isEmpty ? "the host" : host.name), not here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // F4.2 — the effective config, from ssh rather than from a reimplementation of its file
        // format. Keyed on the name, so `.task` cancels and re-runs as the field is edited; the sleep
        // is the debounce, and it is the whole reason a keystroke does not cost a subprocess.
        .task(id: host.name) {
            let name = host.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                resolved = [:]
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let config = await HostConfigStore.resolveEffectiveConfig(for: name)
            guard !Task.isCancelled else { return }
            resolved = config
        }
    }

    /// What the alias turns out to mean, when that is not simply the name typed above.
    ///
    /// The point of the whole editor's "the name is passed straight to ssh" promise is that an alias
    /// carries a real destination, a user, a port and possibly a jump host — none of which was
    /// visible anywhere in the app, so the only way to find out what `Host devbox` resolved to was to
    /// open `~/.ssh/config` and read it, `Include` and `Match` blocks and all. This is `ssh -G`'s
    /// answer, which is the same one the connection will get.
    private var resolvedSummary: String? {
        guard !resolved.isEmpty else { return nil }
        let typed = host.name.trimmingCharacters(in: .whitespaces).lowercased()
        var parts: [String] = []
        if let hostname = resolved["hostname"], hostname.lowercased() != typed {
            parts.append("connects to \(hostname)")
        }
        if let proxy = resolved["proxyjump"], proxy != "none" {
            parts.append("via \(proxy)")
        } else if let command = resolved["proxycommand"], command != "none" {
            parts.append("through a ProxyCommand")
        }
        // Deliberately no identity: `ssh -G` lists every default key when none was configured, so
        // naming one would present a default as a decision.
        guard !parts.isEmpty else { return nil }
        return "ssh resolves this to: " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Authentication

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authentication").font(.subheadline).fontWeight(.semibold)

            Toggle("This host asks for a password", isOn: $host.usesPassword)
            Text("Keys are still tried first — ssh decides that, not tetmux. This only says what should happen when a password prompt appears, since ssh asks on a terminal you cannot see.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if host.usesPassword {
                Grid(alignment: .leading, verticalSpacing: 8) {
                    GridRow {
                        Text("Password").gridColumnAlignment(.trailing)
                        SecureField(
                            draft.host.storesPasswordInKeychain ? "unchanged" : "optional — you can also be asked each time",
                            text: $password
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    }
                }

                Toggle("Save in the login Keychain", isOn: $savePassword)
                if savePassword {
                    Text("Stored as an internet password for \(host.hostname ?? host.name), revocable in Keychain Access. Never written to hosts.json.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if draft.host.storesPasswordInKeychain {
                    Text("Saving off — the existing Keychain entry for this host will be deleted.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - ssh options

    /// The escape hatch for everything the fields above do not cover.
    ///
    /// Placed last because it is the advanced one, and shown with the resulting argv so the effect
    /// of what was typed is visible before the connection is attempted rather than after it fails.
    private var sshOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ssh Options").font(.subheadline).fontWeight(.semibold)

            Toggle("Forward X11 (ssh -X)", isOn: $host.forwardsX11)
            Text("Lets programs in this host's panes open windows on your Mac, which needs an X server such as XQuartz running here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Extra arguments").padding(.top, 4)
            TextField("-o ProxyJump=bastion -C", text: $host.extraSshArguments, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            // ssh takes the *first* value it obtains for a parameter, so these are placed ahead of
            // tetmux's own -o options and genuinely override them. Worth saying: the opposite order
            // would accept the text and silently ignore it.
            Text("Passed to ssh ahead of tetmux's own options, so an -o here overrides the default. Split like a shell would (quotes work), but never run by one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !TmuxCommand.splitArguments(host.extraSshArguments).isEmpty {
                Text(TmuxCommand.splitArguments(host.extraSshArguments).map { "‹\($0)›" }.joined(separator: " "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Forwards

    private var forwardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tunnels").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button {
                    host.forwards.append(PortForward())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add tunnel")
            }

            Text("Set up with the host's ssh connection and gone when it closes. A forward that cannot bind does not stop the session — ssh's complaint appears in the connection error text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if host.forwards.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach($host.forwards) { $forward in
                    forwardRow($forward)
                }
            }
        }
    }

    private func forwardRow(_ forward: Binding<PortForward>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: forward.kind) {
                    ForEach(PortForward.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                TextField("port", value: forward.listenPort, format: .number.grouping(.never))
                    .frame(width: 62)

                if forward.wrappedValue.kind.needsDestination {
                    Text("→").foregroundStyle(.secondary)
                    TextField("host", text: forward.destinationHost).frame(width: 130)
                    TextField("port", value: forward.destinationPort, format: .number.grouping(.never))
                        .frame(width: 62)
                }

                Spacer(minLength: 4)

                Button {
                    host.forwards.removeAll { $0.id == forward.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove tunnel")
            }
            .textFieldStyle(.roundedBorder)

            // Incomplete rows are skipped when connecting rather than passed to ssh, so say so here
            // instead of letting the host quietly connect without its tunnel.
            if !forward.wrappedValue.isValid {
                Text("Incomplete — this tunnel will be skipped.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text(forward.wrappedValue.displayDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Binding where Value == String {
    /// Edits an optional string field in a form without the view having to think about nil.
    init(_ source: Binding<String?>, replacingNilWith empty: String) {
        self.init(
            get: { source.wrappedValue ?? empty },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
