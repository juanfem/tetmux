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

/// One browser, for as long as its socket stays open: the topology it can pick from, the one pane it
/// is looking at, and its keystrokes back.
///
/// **The socket is disposable and the channel is not.** Everything here is torn down when the phone
/// drops the link — which iOS does every time Safari is backgrounded — and nothing upstream notices:
/// the control-mode channels belong to `SessionService`, which outlives every socket. A reconnecting
/// browser is just a new subscriber, and gets a repaint like any second viewer (F4.16).
///
/// **One pane at a time, zoomed.** A phone has room for one pane, so a split window's panes are a
/// second row of tabs rather than a layout. Showing one of them unzoomed would give it its share of a
/// phone-sized window — half of 45 columns for a two-way split — so the relay zooms the pane it shows
/// (`resize-pane -Z`), and unzooms on the way out when the zoom was its own. Zoom is a property of
/// the tmux window, not of a client, so a Mac looking at the same window sees it zoomed too; that is
/// the same trade the window size already makes (§3.3), and undone the same way.
actor PaneBridge {
    private let service: SessionService
    private let registry: ViewRegistry
    private let writer: FrameWriter
    /// This socket in the registry.
    private let socket = UUID()
    /// This socket's claim on the size of whichever tmux window it is showing (§3.3). One owner per
    /// window: the latest browser to connect, or to ask, is the one that sizes it.
    private let owner = UUID()

    private var hosts: [HostState] = []
    /// What the browser asked for, updated to what it got. `nil` until its first `view`: nothing is
    /// subscribed before then.
    private var wanted: ViewRequest?
    private var showing: ViewTarget?
    private var pump: Task<Void, Never>?
    /// Bumped by every `show`, so one that was overtaken during its `await` knows to stop.
    private var generation = 0
    private var subscriber: UUID?
    /// Whether the session being shown had a client streaming it, last time this looked.
    private var showingIsLive = false
    private var lastSize: (cols: Int, rows: Int)?
    private var lastTopology: Wire.Topology?
    /// What the browser last asked for, kept so a window change can ask again on its behalf.
    private var desired: (cols: Int, rows: Int)?
    /// Windows this socket zoomed and has not unzoomed, keyed by host and window.
    private var zoomedByUs: Set<WindowKey> = []
    /// When each zoom toggle was sent. `resize-pane -Z` *toggles*, so a second toggle sent before
    /// tmux's answer to the first has arrived would read a stale snapshot and undo it.
    private var zoomSentAt: [WindowKey: ContinuousClock.Instant] = [:]

    private struct WindowKey: Hashable {
        let host: String
        let window: String
    }

    init(service: SessionService, registry: ViewRegistry, outbound: WebSocketOutboundWriter) {
        self.service = service
        self.registry = registry
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

        switch message.t {
        case "view":
            await view(ViewRequest(
                host: message.host, session: message.session, window: message.window, pane: message.pane
            ))
        case "in":
            guard let showing, let data = message.d, !data.isEmpty else { return }
            await service.sendKeys(hostId: showing.host, paneId: showing.pane, bytes: Array(data.utf8))
        case "paste":
            // Through `paste`, not `send-keys`: tmux adds bracketed-paste markers only when the pane's
            // program asked for them, and a large paste goes through a buffer instead of a megabyte
            // of hex on one command line (§3.2).
            guard let showing, let data = message.d, !data.isEmpty else { return }
            await service.paste(hostId: showing.host, paneId: showing.pane, text: data)
        case "resize":
            guard let cols = message.cols, let rows = message.rows, cols > 1, rows > 1 else { return }
            desired = (cols, rows)
            await requestSize()
        default:
            break
        }
    }

    private func view(_ request: ViewRequest) async {
        wanted = request
        // Picking a host that is down is asking for it to be connected — the relay connects only the
        // hosts it was started with, and the rest on first look. `openHost` also cuts short a
        // reconnect backoff, which is what a person tapping the host means.
        if let hostId = request.host, let host = hosts.first(where: { $0.id == hostId }) {
            switch host.connectionState {
            case .disconnected, .failed, .reconnecting:
                Task { [service] in await service.openHost(hostId: hostId) }
            case .connecting, .connected, .degraded:
                break
            }
        }
        await refresh(explicit: true)
    }

    /// Asks tmux for the browser's size. Nothing on the browser resizes until the answer comes back
    /// as a `size` frame (§3.3).
    private func requestSize() async {
        guard let showing, let desired else { return }
        await service.claimWindowSize(hostId: showing.host, windowId: showing.window, owner: owner)
        await service.requestWindowSize(
            hostId: showing.host, windowId: showing.window, cols: desired.cols, rows: desired.rows, owner: owner
        )
        // For tmux older than 2.9, which has no per-window size and sizes from the client instead.
        await service.requestClientSize(hostId: showing.host, cols: desired.cols, rows: desired.rows)
    }

    // MARK: - tmux → browser

    private func apply(_ hosts: [HostState]) async {
        self.hosts = hosts
        let topology = Wire.Topology(hosts)
        if topology != lastTopology {
            lastTopology = topology
            await writer.text(Wire.encode(topology))
        }
        await refresh(explicit: false)
    }

    /// Brings what is shown in line with what was asked for and what exists.
    ///
    /// `explicit` is a tap: the browser asked again, so a zoom that something else undid since — a
    /// split from the Mac unzooms the window — is put back. A topology change alone never re-zooms,
    /// or the relay would fight anyone at the Mac who unzoomed on purpose.
    private func refresh(explicit: Bool) async {
        guard let wanted else { return }
        // Nothing to show — the host asked for is still connecting, say. The last pane stays up,
        // and the topology tells the page why.
        guard let target = ViewResolver.resolve(wanted, in: hosts) else { return }

        guard target == showing else {
            await show(target)
            return
        }
        if let pane = hosts.first(where: { $0.id == target.host })?.pane(target.pane) {
            await reportSize(cols: pane.cols, rows: pane.rows)
        }
        await repaintIfItWentLive(target)
        if explicit { await ensureZoom(target) }
    }

    private func show(_ target: ViewTarget) async {
        if let previous = showing, previous.host != target.host || previous.window != target.window {
            await service.releaseWindowSize(hostId: previous.host, windowId: previous.window, owner: owner)
            await unzoomIfOurs(previous)
        }
        pump?.cancel()
        pump = nil
        generation += 1
        let generation = self.generation
        showing = target
        wanted = ViewRequest(target)
        await registry.set(socket, host: target.host, session: target.session)

        let host = hosts.first { $0.id == target.host }
        let pane = host?.pane(target.pane)
        lastSize = (pane?.cols ?? 0, pane?.rows ?? 0)
        showingIsLive = host?.liveSessionIds.contains(target.session) ?? false

        let subscription = await service.subscribeToPane(hostId: target.host, paneId: target.pane)
        // Re-entrancy: another `view`, or a snapshot that re-showed this one, may have landed during
        // that await. The subscription is dropped with its stream, which ends it.
        guard self.generation == generation else { return }
        subscriber = subscription.id

        let header = Wire.encode(Wire.Pane(
            host: target.host, session: target.session, window: target.window, pane: target.pane,
            cols: pane?.cols ?? 0, rows: pane?.rows ?? 0
        ))
        let (service, writer) = (self.service, self.writer)
        pump = Task {
            // The header first, from the same task that writes the bytes, so it can never land after
            // the repaint it introduces. The repaint is already waiting in the stream's buffer.
            guard await writer.text(header) else { return }
            for await data in subscription.stream {
                guard await writer.binary(data) else { return }
                // Acknowledged once NIO has taken the frame, which is the closest this side gets to
                // "the viewer kept up" (P6.5). A phone on a bad link stops acknowledging, and the
                // pane is paused rather than queued without bound in this process.
                await service.acknowledge(
                    hostId: target.host, paneId: target.pane, subscriber: subscription.id, bytes: data.count
                )
            }
            // The service ended the stream — the pane went, or its channel did. Shown again on the
            // next snapshot that has something to show.
            if !Task.isCancelled { self.streamEnded(generation) }
        }

        await ensureZoom(target)
        await requestSize()
    }

    private func streamEnded(_ ended: Int) {
        guard generation == ended else { return }
        pump = nil
        showing = nil
    }

    /// A session with no client of ours streams nothing (`liveSessionIds`). Showing one asks the
    /// registry for a client, and the repaint taken at subscribe time predates it — so whatever the
    /// pane printed in between would be missing. Repaint again once the client is attached.
    private func repaintIfItWentLive(_ target: ViewTarget) async {
        let live = hosts.first { $0.id == target.host }?.liveSessionIds.contains(target.session) ?? false
        defer { showingIsLive = live }
        guard live, !showingIsLive, let subscriber else { return }
        await service.repaintPane(hostId: target.host, paneId: target.pane, subscriber: subscriber)
    }

    // MARK: - Zoom

    private func ensureZoom(_ target: ViewTarget) async {
        let key = WindowKey(host: target.host, window: target.window)
        guard let window = hosts.first(where: { $0.id == target.host })?.window(target.window),
              window.paneCount > 1, !zoomIsInFlight(key) else { return }

        if !window.isZoomed {
            await service.selectPane(hostId: target.host, paneId: target.pane)
            await service.toggleZoom(hostId: target.host, paneId: target.pane)
            zoomedByUs.insert(key)
        } else if window.activePaneId != target.pane {
            // Zoomed on another pane. `select-pane -Z` would keep the zoom across the move, but only
            // from tmux 3.1; unzoom, select, zoom works on every version this supports. Whoever
            // zoomed it, it is the same zoom afterwards, so ownership does not change.
            if let active = window.activePaneId {
                await service.toggleZoom(hostId: target.host, paneId: active)
            }
            await service.selectPane(hostId: target.host, paneId: target.pane)
            await service.toggleZoom(hostId: target.host, paneId: target.pane)
        } else {
            return
        }
        zoomSentAt[key] = .now
    }

    private func unzoomIfOurs(_ target: ViewTarget) async {
        let key = WindowKey(host: target.host, window: target.window)
        guard zoomedByUs.remove(key) != nil else { return }
        // Already unzoomed by someone else, or gone: nothing to put back.
        guard let window = hosts.first(where: { $0.id == target.host })?.window(target.window),
              window.isZoomed, !zoomIsInFlight(key) else { return }
        await service.toggleZoom(hostId: target.host, paneId: window.activePaneId ?? target.pane)
        zoomSentAt[key] = .now
    }

    private func zoomIsInFlight(_ key: WindowKey) -> Bool {
        guard let sent = zoomSentAt[key] else { return false }
        return ContinuousClock.now - sent < .seconds(1)
    }

    // MARK: - Reporting

    private func reportSize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        if let lastSize, lastSize == (cols, rows) { return }
        lastSize = (cols, rows)
        await writer.text(Wire.encode(Wire.Size(cols: cols, rows: rows)))
    }

    private func teardown() async {
        pump?.cancel()
        pump = nil
        if let showing {
            await service.releaseWindowSize(hostId: showing.host, windowId: showing.window, owner: owner)
            await unzoomIfOurs(showing)
        }
        showing = nil
        await registry.remove(socket)
    }
}
