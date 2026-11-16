import Foundation
import HummingbirdWebSocket
import NIOCore
import tetmuxCore

/// Serialises everything one socket sends, so a pane's header always precedes its bytes and a write
/// is only reported done once NIO has taken it.
///
/// Chained tasks rather than plain actor methods: an actor is re-entrant at every `await`, so two
/// writes awaiting the socket could still overtake each other. Each write waits for the one before.
actor FrameWriter {
    private let outbound: WebSocketOutboundWriter
    private var tail: Task<Bool, Never>?

    init(outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    /// Whether the frame went out. `false` means the socket is gone and the caller should stop.
    @discardableResult
    func write(_ frame: WebSocketOutboundWriter.OutboundFrame) async -> Bool {
        let previous = tail
        let outbound = self.outbound
        let task = Task<Bool, Never> {
            guard await previous?.value ?? true else { return false }
            do {
                try await outbound.write(frame)
                return true
            } catch {
                return false
            }
        }
        tail = task
        return await task.value
    }

    @discardableResult
    func text(_ string: String) async -> Bool {
        await write(.text(string))
    }

    func binary(_ data: Data) async -> Bool {
        await write(.binary(ByteBuffer(bytes: data)))
    }
}

/// One browser's view of one pane, for as long as its socket stays open.
///
/// Step 2's whole job: show the active pane of the attached session, follow it if it goes away,
/// carry keystrokes back, and let the browser ask for a size. Which pane to show is the relay's
/// choice for now; picking one is step 3's protocol.
///
/// **The socket is disposable and the channel is not.** Everything here is torn down when the phone
/// drops the link — which iOS does every time Safari is backgrounded — and nothing upstream notices:
/// the control-mode channel belongs to `SessionService`, which outlives every socket. A reconnecting
/// browser is just a new subscriber, and gets a repaint like any second viewer (F4.16).
actor PaneBridge {
    private let service: SessionService
    private let hostId: String
    private let writer: FrameWriter
    /// This socket's claim on the size of whichever tmux window it is showing (§3.3). One owner per
    /// window: the latest browser to connect, or to ask, is the one that sizes it.
    private let owner = UUID()

    private var current: (windowId: String, paneId: String)?
    private var pump: Task<Void, Never>?
    private var lastSize: (cols: Int, rows: Int)?
    private var lastStatus: String?
    /// What the browser last asked for, kept so a window change can ask again on its behalf.
    private var desired: (cols: Int, rows: Int)?

    init(service: SessionService, hostId: String, outbound: WebSocketOutboundWriter) {
        self.service = service
        self.hostId = hostId
        self.writer = FrameWriter(outbound: outbound)
    }

    func run(inbound: WebSocketInboundStream) async {
        let follower = Task { [service] in
            for await hosts in await service.stateStream() {
                guard !Task.isCancelled else { break }
                await self.apply(hosts)
            }
        }

        do {
            for try await message in inbound.messages(maxSize: 1 << 20) {
                if case .text(let text) = message {
                    await handle(text)
                }
                // A binary frame from the browser means nothing yet; input is JSON so that a
                // keystroke and a paste stay distinguishable (T5.4).
            }
        } catch {
            // The socket closed under us. Same outcome as a clean close.
        }

        follower.cancel()
        await teardown()
    }

    // MARK: - Browser → tmux

    private func handle(_ text: String) async {
        guard let message = try? JSONDecoder().decode(Wire.Inbound.self, from: Data(text.utf8)) else { return }
        guard let paneId = current?.paneId else {
            if message.t == "resize", let cols = message.cols, let rows = message.rows {
                desired = (cols, rows)
            }
            return
        }

        switch message.t {
        case "in":
            guard let data = message.d, !data.isEmpty else { return }
            await service.sendKeys(hostId: hostId, paneId: paneId, bytes: Array(data.utf8))
        case "paste":
            // Through `paste`, not `send-keys`: tmux adds bracketed-paste markers only when the pane's
            // program asked for them, and a large paste goes through a buffer instead of a megabyte
            // of hex on one command line (§3.2).
            guard let data = message.d, !data.isEmpty else { return }
            await service.paste(hostId: hostId, paneId: paneId, text: data)
        case "resize":
            guard let cols = message.cols, let rows = message.rows, cols > 1, rows > 1 else { return }
            desired = (cols, rows)
            await requestSize()
        default:
            break
        }
    }

    /// Asks tmux for the browser's size. Nothing on the browser resizes until the answer comes back
    /// as a `size` frame (§3.3).
    private func requestSize() async {
        guard let windowId = current?.windowId, let desired else { return }
        await service.claimWindowSize(hostId: hostId, windowId: windowId, owner: owner)
        await service.requestWindowSize(
            hostId: hostId, windowId: windowId, cols: desired.cols, rows: desired.rows, owner: owner
        )
        // For tmux older than 2.9, which has no per-window size and sizes from the client instead.
        await service.requestClientSize(hostId: hostId, cols: desired.cols, rows: desired.rows)
    }

    // MARK: - tmux → browser

    private func apply(_ hosts: [HostState]) async {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        await reportStatus(of: host)

        guard let session = host.activeSession else { return }
        // Keep the pane being shown for as long as it exists. Following tmux's active pane on every
        // snapshot would yank the screen away whenever somebody at the Mac clicked another split.
        if let current, let window = session.windows.first(where: { $0.id == current.windowId }),
           let pane = window.panes.first(where: { $0.id == current.paneId }) {
            await reportSize(cols: pane.cols, rows: pane.rows)
            return
        }

        guard let window = session.activeWindow, let paneId = window.preferredPaneId else { return }
        let pane = window.panes.first { $0.id == paneId }
        await show(
            session: session, window: window, paneId: paneId,
            cols: pane?.cols ?? 0, rows: pane?.rows ?? 0
        )
    }

    private func show(session: TmuxSession, window: TmuxWindow, paneId: String, cols: Int, rows: Int) async {
        if let previous = current, previous.windowId != window.id {
            await service.releaseWindowSize(hostId: hostId, windowId: previous.windowId, owner: owner)
        }
        pump?.cancel()
        current = (window.id, paneId)
        lastSize = (cols, rows)

        let header = Wire.encode(Wire.Pane(
            host: hostId, session: session.name, window: window.id, pane: paneId,
            label: window.displayLabel, cols: cols, rows: rows
        ))
        let (service, hostId, writer) = (self.service, self.hostId, self.writer)
        pump = Task {
            // The header first, from the same task that will write the bytes, so it can never land
            // after the repaint it introduces.
            guard await writer.text(header) else { return }
            let subscription = await service.subscribeToPane(hostId: hostId, paneId: paneId)
            for await data in subscription.stream {
                guard await writer.binary(data) else { break }
                // Acknowledged once NIO has taken the frame, which is the closest this side gets to
                // "the viewer kept up" (P6.5). A phone on a bad link stops acknowledging, and the
                // pane is paused rather than queued without bound in this process.
                await service.acknowledge(
                    hostId: hostId, paneId: paneId, subscriber: subscription.id, bytes: data.count
                )
            }
        }

        await requestSize()
    }

    private func reportSize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        if let lastSize, lastSize == (cols, rows) { return }
        lastSize = (cols, rows)
        await writer.text(Wire.encode(Wire.Size(cols: cols, rows: rows)))
    }

    private func reportStatus(of host: HostState) async {
        let state = String(describing: host.connectionState)
        // ssh is waiting on something the relay has no way to answer yet — a password, a host key.
        // Said, so the page shows why nothing is happening, rather than looking hung.
        let text = host.authenticationPrompt.map { "ssh is waiting: \($0.text)" }
        let key = state + (text ?? "")
        guard key != lastStatus else { return }
        lastStatus = key
        await writer.text(Wire.encode(Wire.Status(state: state, text: text)))
    }

    private func teardown() async {
        pump?.cancel()
        pump = nil
        if let windowId = current?.windowId {
            await service.releaseWindowSize(hostId: hostId, windowId: windowId, owner: owner)
        }
        current = nil
    }
}
