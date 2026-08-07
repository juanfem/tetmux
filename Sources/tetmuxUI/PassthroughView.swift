import AppKit
import SwiftTerm
import SwiftUI
import tetmuxCore

/// F4.27 / §4.6 — the whole of a host control mode cannot drive.
///
/// This replaces the tab strip, the pane tree and the status bar rather than sitting beside them,
/// because in this mode none of them has anything to show: there is one tmux client painting itself
/// into one surface, with tmux's own status bar and prefix key doing the jobs tetmux normally does.
/// The GUI splits are not disabled by a flag anywhere — they are simply not on screen, and the menu
/// items behind them act on a scope this host does not have.
struct PassthroughView: View {
    let host: HostState
    let theme: TerminalTheme
    let service: SessionService
    let onStart: () -> Void
    let onTryControlMode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let state = host.passthrough {
                banner(state)
                Divider()
                if state.isRunning {
                    // Framed from a `GeometryReader`, exactly as `TerminalContainerView` frames a
                    // pane. An `NSViewRepresentable`'s ideal size is its view's fitting size, which
                    // for a `TerminalView` is whatever grid it happens to hold — not something to
                    // leave to chance beside a column that sizes itself to its content.
                    GeometryReader { proxy in
                        PassthroughTerminalView(
                            hostId: host.id,
                            theme: theme,
                            allowsRemoteClipboardWrite: host.config.allowRemoteClipboardWrite,
                            service: service
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                } else {
                    placeholder(state)
                }
            }
        }
    }

    /// The mode indicator the requirement asks for, and it stays on screen for as long as the mode
    /// does — this is the one thing that explains why the tabs and the tree are gone.
    private func banner(_ state: PassthroughState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.usesTmux ? "rectangle.on.rectangle" : "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.summary).font(.caption).lineLimit(2).fontWeight(.medium)
                // `lineLimit`, and deliberately *not* `fixedSize(horizontal: false, vertical: true)`,
                // which is what the other multi-line labels in this app use. Those all sit in
                // fixed-width containers; this one is in a `NavigationSplitView` detail column, which
                // measures its content with an unspecified width — and a fixed-size text answers that
                // by wrapping at one character per line and reporting the height that implies. The
                // split view grew to 1640pt inside a 612pt window, centred it, and pushed *both*
                // columns' content off the top: an empty-looking window whose accessibility tree was
                // complete, with every sidebar row at a negative screen Y. The banners in `AppMain`
                // have always used `lineLimit` for the same reason.
                Text(state.consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.summary) \(state.consequence)")
    }

    /// Before it is started, and after it has ended. `tmuxUnavailable` always begins here: there is
    /// nothing to reattach to on that host, so opening a shell nobody asked for would be inventing
    /// the one thing this mode cannot promise.
    private func placeholder(_ state: PassthroughState) -> some View {
        VStack(spacing: 14) {
            Image(systemName: state.usesTmux ? "rectangle.on.rectangle" : "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(host.config.name).font(.title2).fontWeight(.semibold)

            // §7 — what the far end said, verbatim, in the shape everything else in the app shows a
            // transcript in.
            if !detail(state).isEmpty {
                ScrollView {
                    Text(detail(state))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, maxHeight: 120)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }

            HStack(spacing: 10) {
                Button(startTitle(state), action: onStart).buttonStyle(.borderedProminent)
                // The way back. A host whose tmux was upgraded, or one that was simply unreachable
                // when it was first tried, has no other route to control mode — the fallback state is
                // `.degraded`, which counts as connected, so nothing would retry on its own.
                Button("Try Control Mode", action: onTryControlMode)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ state: PassthroughState) -> String {
        if case .ended(let reason) = state.phase { return reason }
        return state.detail
    }

    private func startTitle(_ state: PassthroughState) -> String {
        if case .ended = state.phase { return state.usesTmux ? "Reattach" : "Open Another Shell" }
        return state.usesTmux ? "Attach in Passthrough" : "Open a Plain Shell"
    }
}

/// The passthrough surface: one emulator, one pty, no protocol in between.
///
/// The differences from `TerminalPaneView` are the whole of what passthrough means. Bytes come from
/// a process rather than from `%output`; keystrokes go out as raw bytes rather than as `send-keys`;
/// and the size is **this view's to decide**, which is the deliberate exception to §3.3. There tmux
/// owns geometry because tmux is laying panes out and reporting where they went. Here the view *is*
/// the client's terminal, so its size is what `TIOCSWINSZ` carries and tmux is downstream of it —
/// asking tmux first would be asking it about a number it is waiting for from us.
struct PassthroughTerminalView: NSViewRepresentable {
    let hostId: String
    let theme: TerminalTheme
    let allowsRemoteClipboardWrite: Bool
    let service: SessionService

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.terminalDelegate = context.coordinator
        view.getTerminal().changeScrollback(theme.scrollbackLines)
        TerminalTheme.quietParserLogging(view.getTerminal())
        view.font = theme.resolvedFont()
        // The same gutter reclaim as a pane, for a plainer reason: nothing else is going to use those
        // 17 points, and SwiftTerm derives its own column count from the frame minus them.
        TerminalPaneView.hideReservedScroller(in: view)
        view.allowMouseReporting = true
        view.optionAsMetaKey = true
        // §4.6's surface takes the scheme too. It is one tmux client painting itself, so its colours
        // are the user's terminal colours by exactly the same argument — a pane that changed scheme
        // while the fallback did not would look like the fallback was somebody else's application.
        TerminalPaneView.applyColors(theme.colorScheme, to: view)

        view.setAccessibilityElement(true)
        view.setAccessibilityRole(NSAccessibility.Role.textArea)
        view.setAccessibilityLabel("Passthrough terminal for \(hostId)")

        context.coordinator.attach(view: view, hostId: hostId, service: service)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self
        TerminalPaneView.hideReservedScroller(in: view)
        if view.font.fontName != theme.resolvedFont().fontName || view.font.pointSize != theme.fontSize {
            view.font = theme.resolvedFont()
        }
        let terminal = view.getTerminal()
        if terminal.options.scrollback != theme.scrollbackLines {
            terminal.changeScrollback(theme.scrollbackLines)
        }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var parent: PassthroughTerminalView
        private weak var view: TerminalView?
        private var subscription: Task<Void, Never>?

        init(parent: PassthroughTerminalView) {
            self.parent = parent
        }

        deinit { subscription?.cancel() }

        func attach(view: TerminalView, hostId: String, service: SessionService) {
            self.view = view
            subscription?.cancel()
            subscription = Task { [weak view] in
                let subscription = await service.subscribeToPassthrough(hostId: hostId)
                // No acknowledgement loop, because there is nothing to tell: the pause that P6.5's
                // accounting exists to trigger is `refresh-client -A`, which is tmux 3.2 — and this
                // mode exists precisely for servers that do not have it. The service's stream bound
                // is the whole of the backpressure here.
                for await data in subscription.stream {
                    if Task.isCancelled { break }
                    guard let view else { break }
                    let bytes = [UInt8](data)
                    view.feed(byteArray: bytes[...])
                }
            }
            // The size the emulator already worked out from its frame, before any resize arrives.
            // Without this the far end stays at the 80x24 it was spawned with until the user drags
            // the window, and tmux draws its status bar across the wrong width.
            let terminal = view.getTerminal()
            report(cols: terminal.cols, rows: terminal.rows)
        }

        func detach() {
            subscription?.cancel()
            subscription = nil
            view = nil
        }

        private func report(cols: Int, rows: Int) {
            let hostId = parent.hostId
            let service = parent.service
            Task { await service.resizePassthrough(hostId: hostId, cols: cols, rows: rows) }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            let hostId = parent.hostId
            let service = parent.service
            Task { await service.sendPassthrough(hostId: hostId, bytes: bytes) }
        }

        /// Acted on here, unlike in a pane.
        ///
        /// A pane ignores this because it fires when SwiftTerm re-derives its grid from a frame tmux
        /// just dictated, so responding is reacting to our own last action. In passthrough there is
        /// no such loop: nothing sizes this view but the window, and the pty is told what the view
        /// worked out. Two macOS windows on one passthrough host therefore take turns, last one
        /// winning — which is exactly what two tmux clients of different sizes do to each other.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            report(cols: newCols, rows: newRows)
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func bell(source: TerminalView) {
            NSSound.beep()
            guard !NSApp.isActive else { return }
            BellNotifier.shared.post(paneId: parent.hostId)
        }

        /// T5.5 — the same allowlist a pane's links are held to. Nothing about arriving over a
        /// passthrough channel makes a URL from a remote machine more trustworthy.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            TerminalPaneView.openExternalLink(link)
        }

        /// T5.6 — the host's own opt-in, exactly as in a pane. A shared box reached with an old tmux
        /// is not more trusted with the clipboard for being old.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard parent.allowsRemoteClipboardWrite else { return }
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
