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

        // Long enough for the attach handshake, the version probe, and the topology queries.
        try? await Task.sleep(for: .seconds(4))

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
            let stream = await service.subscribeToPane(hostId: hostId, paneId: paneId)
            let reader = Task {
                var received = 0
                for await data in stream {
                    received += data.count
                    FileHandle.standardOutput.write(data)
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
}
