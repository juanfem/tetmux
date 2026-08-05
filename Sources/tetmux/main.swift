import Foundation
import tetmuxCore
import tetmuxUI

// `tetmux --diagnose [host]` is the Phase 1 exit criterion: a CLI that prints the event stream from
// a live tmux, with no UI in the way. It is the first thing to reach for when a host misbehaves,
// because it separates "the protocol layer is wrong" from "the views are wrong".
if CommandLine.arguments.contains("--diagnose") {
    await Diagnostics.run(arguments: CommandLine.arguments)
    exit(0)
}

TetmuxApp.main()

enum Diagnostics {
    static func run(arguments: [String]) async {
        let requested = arguments.drop { $0 != "--diagnose" }.dropFirst().first

        // Resolve against the saved host list so the CLI exercises the exact configuration the UI
        // would use — user, port, and custom command included. Diagnosing a host with different
        // settings than the app uses is worse than not diagnosing it.
        let stored = await HostConfigStore().loadHosts()
        let config: HostConfig
        if let requested {
            if let match = stored.first(where: { $0.id == requested || $0.name == requested }) {
                config = match.asConfig
            } else {
                config = HostConfig(id: requested, name: requested, isLocal: false)
            }
        } else {
            config = stored.first { $0.isLocal }?.asConfig
                ?? HostConfig(id: "local", name: "localhost", isLocal: true)
        }
        let hostId = config.id

        let service = SessionService()
        await service.setDiagnosticLogger { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        await service.addHost(config)

        print("→ connecting to \(config.name) [\(hostId)] (\(config.isLocal ? "local tmux" : "ssh \(config.sshDestination) port \(config.port.map(String.init) ?? "22")"))…")
        do {
            try await service.connectHost(hostId: hostId, targetSession: "tetmux-diagnose")
        } catch {
            print("✘ connect failed: \(error)")
            return
        }

        // A password host would otherwise sit here until ssh gave up: the prompt is on a pty with no
        // UI attached to it. The Keychain is the only source available without a sheet — a passphrase
        // or a second factor is reported and left alone.
        let answering = Task { await answerPrompts(service: service, config: config) }

        // Long enough for the attach handshake, the version probe, and the topology queries.
        try? await Task.sleep(for: .seconds(4))
        answering.cancel()

        guard let host = await service.getHost(hostId) else {
            print("✘ host disappeared")
            return
        }

        print("\nstate:   \(host.connectionState)")
        print("tmux:    \(host.tmuxVersion ?? "unknown")")
        if let rtt = host.rttMilliseconds {
            print("rtt:     \(String(format: "%.1f ms", rtt))")
        }
        print("sessions: \(host.sessions.count)")
        for session in host.sessions {
            print("  \(session.id) \(session.name)\(session.isAttached ? " [attached]" : "")")
            for window in session.windows {
                print("    \(window.id) \(window.name) — \(window.paneCount) pane(s)")
                print("      layout: \(window.layoutString)")
                print("      tree:   \(window.layoutTree.map { "\($0.paneIds)" } ?? "UNPARSED")")
                for pane in window.panes {
                    print("      \(pane.id) \(pane.cols)x\(pane.rows) \(pane.command) \(pane.currentPath)")
                }
            }
        }

        // Prove the output plane works end to end: subscribe, type, and read the echo back.
        if let paneId = host.activeSession?.activeWindow?.preferredPaneId {
            print("\n→ subscribing to \(paneId) and sending `echo tetmux-ok`…")
            let subscription = await service.subscribeToPane(hostId: hostId, paneId: paneId)
            let reader = Task {
                var received = 0
                for await data in subscription.stream {
                    received += data.count
                    FileHandle.standardOutput.write(data)
                    // Acknowledged as it goes, like a real viewer: an unacknowledged reader looks to
                    // the service exactly like one that has fallen behind, and would have its pane
                    // paused out from under it.
                    await service.acknowledge(
                        hostId: hostId, paneId: paneId, subscriber: subscription.id, bytes: data.count
                    )
                    if received > 8192 { break }
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            await service.sendKeys(hostId: hostId, paneId: paneId, text: "echo tetmux-ok\r")
            try? await Task.sleep(for: .seconds(2))
            reader.cancel()
            print("\n")
        }

        await service.disconnectHost(hostId: hostId)
        print("→ done")
    }

    /// Answers a password prompt from the Keychain, once, while the diagnostic connect is in flight.
    private static func answerPrompts(service: SessionService, config: HostConfig) async {
        var answered = false
        while !Task.isCancelled, !answered {
            guard let prompt = await service.getHost(config.id)?.authenticationPrompt else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            switch prompt.kind {
            case .password where config.storesPasswordInKeychain:
                if let stored = await KeychainStore.password(for: config) {
                    print("→ answering \(prompt.text.debugDescription) from the Keychain")
                    await service.answerAuthenticationPrompt(hostId: config.id, secret: stored)
                } else {
                    print("✘ \(prompt.text.debugDescription) — no Keychain entry for this host")
                }
            case .password:
                print("✘ \(prompt.text.debugDescription) — this host has no stored password; the app would prompt")
            case .keyPassphrase:
                print("✘ \(prompt.text.debugDescription) — add the key to your ssh agent")
            case .hostKey:
                // The CLI answers nothing here on purpose. Accepting a host key is a decision with
                // the fingerprint in front of the person making it, and `--diagnose` prints to a
                // terminal that may not have one in front of anybody.
                print("✘ \(prompt.text.debugDescription) — a host key needs deciding; the app would ask")
                if let context = prompt.context { print(context) }
            case .question:
                print("✘ \(prompt.text.debugDescription) — ssh is waiting on this; the app would ask")
            }
            answered = true
        }
    }
}
