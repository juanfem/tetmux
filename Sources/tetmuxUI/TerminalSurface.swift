import AppKit
import SwiftTerm
import SwiftUI
import tetmuxCore

/// User-visible terminal appearance. Kept in one place so the eventual settings pane has a single
/// thing to write to, and so both backends behind `TerminalSurface` would read the same values.
public struct TerminalTheme: Equatable, Sendable {
    public var fontName: String
    public var fontSize: CGFloat
    /// T5.8 — ligatures off by default.
    public var ligatures: Bool
    /// T5.6 — a remote host silently overwriting the local clipboard is an injection vector, so
    /// OSC 52 writes are denied unless the user opts in per host. Reads are never permitted.
    public var allowRemoteClipboardWrite: Bool

    public static let `default` = TerminalTheme(
        fontName: "SF Mono",
        fontSize: 12,
        ligatures: false,
        allowRemoteClipboardWrite: false
    )

    public func resolvedFont() -> NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// The size of one character cell, from the font.
    ///
    /// Deliberately *not* measured from a pane. A pane can only report its own frame divided by its
    /// own cell count, and that is a circular measurement: the frame comes from the layout, the layout
    /// comes from the size we asked tmux for, and the size we ask for comes from the cell size. With a
    /// single pane the circle is stable and nobody notices. With a split window each pane divides a
    /// different frame by a different cell count, so they report *different* cell sizes — 8.31, 8.39,
    /// 8.46 for one 3-pane window — whichever reported last won, and the requested width oscillated
    /// between 111 and 112 columns forever. That was the separator flicker.
    ///
    /// A font's cell size depends on nothing but the font, so computing it here breaks the loop at its
    /// source. Mirrors SwiftTerm's own `computeFontDimensions` so the grid we ask for is the grid it
    /// draws: ascent + descent + leading for the height, the advancement of `W` for the width, both
    /// snapped up to the pixel grid to avoid sub-pixel seams between cells.
    public func cellSize(backingScaleFactor scale: CGFloat) -> CGSize {
        let font = resolvedFont()
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let scale = scale > 0 ? scale : 1
        return CGSize(
            width: max(1, ceil(width * scale) / scale),
            height: max(1, min(ceil(height * scale) / scale, 8192))
        )
    }
}

/// One tmux pane, rendered by SwiftTerm.
///
/// This is the replaceable component behind the `TerminalSurface` seam described in §2.3 — nothing
/// above it knows which emulator is drawing. It owns no PTY and no child process: bytes arrive from
/// `SessionService`, keystrokes go back out as `send-keys`.
struct TerminalPaneView: NSViewRepresentable {
    let hostId: String
    let paneId: String
    /// Cell size tmux assigned this pane. tmux is authoritative; the view never picks its own.
    let cols: Int
    let rows: Int
    let isFocused: Bool
    let theme: TerminalTheme
    let service: SessionService
    let onFocusRequest: () -> Void

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.terminalDelegate = context.coordinator
        view.font = theme.resolvedFont()
        view.allowMouseReporting = true   // T5.3
        view.optionAsMetaKey = true
        view.configureNativeColors()

        context.coordinator.attach(view: view, hostId: hostId, paneId: paneId, service: service)
        if cols > 0 && rows > 0 {
            view.resize(cols: cols, rows: rows)
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self

        if view.font.fontName != theme.resolvedFont().fontName || view.font.pointSize != theme.fontSize {
            view.font = theme.resolvedFont()
        }

        // Snap the emulator to the size tmux reported. If the view's own pixel-derived size drifts
        // by a cell, output wraps at the wrong column and the grid desynchronises (§3.3).
        let terminal = view.getTerminal()
        if cols > 0, rows > 0, terminal.cols != cols || terminal.rows != rows {
            view.resize(cols: cols, rows: rows)
        }

        if isFocused, view.window?.firstResponder !== view {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var parent: TerminalPaneView
        private weak var view: TerminalView?
        private var subscription: Task<Void, Never>?

        init(parent: TerminalPaneView) {
            self.parent = parent
        }

        deinit {
            subscription?.cancel()
        }

        /// Bytes fed before telling the service about it. An acknowledgement per chunk would be an
        /// actor hop per chunk, which costs more than the accounting is worth; the service's
        /// thresholds are three orders of magnitude above this, so a batch in flight never decides
        /// anything.
        private let acknowledgeAfterBytes = 16 * 1024

        func attach(view: TerminalView, hostId: String, paneId: String, service: SessionService) {
            self.view = view
            subscription?.cancel()
            subscription = Task { [weak view, acknowledgeAfterBytes] in
                let subscription = await service.subscribeToPane(hostId: hostId, paneId: paneId)
                // Feeding happens here, on the main actor, so this loop *is* the paint rate. Reporting
                // what it has consumed is what lets the service see a viewer falling behind and pause
                // the pane (P6.5) — the producer side of an `AsyncStream` cannot observe that itself.
                var unacknowledged = 0
                for await data in subscription.stream {
                    if Task.isCancelled { break }
                    guard let view else { break }
                    let bytes = [UInt8](data)
                    view.feed(byteArray: bytes[...])

                    unacknowledged += data.count
                    if unacknowledged >= acknowledgeAfterBytes {
                        await service.acknowledge(
                            hostId: hostId, paneId: paneId,
                            subscriber: subscription.id, bytes: unacknowledged
                        )
                        unacknowledged = 0
                    }
                }
            }
        }

        func detach() {
            subscription?.cancel()
            subscription = nil
            view = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Raw bytes, not a String round trip: an Alt-chord or a non-UTF-8 key sequence must
            // reach the pane byte-for-byte.
            let bytes = Array(data)
            let hostId = parent.hostId
            let paneId = parent.paneId
            let service = parent.service
            parent.onFocusRequest()
            Task { await service.sendKeys(hostId: hostId, paneId: paneId, bytes: bytes) }
        }

        /// Deliberately ignored. tmux owns geometry (§3.3): the container measures itself, asks tmux,
        /// and lays out whatever `%layout-change` returns. This fires when SwiftTerm re-derives its own
        /// grid from the frame we just gave it, so acting on it would be reacting to our own last
        /// action — which is precisely the loop that made split windows redraw forever.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) { NSSound.beep() }

        /// T5.5 — OSC 8 hyperlinks open in the default handler.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return }
            // Only schemes that cannot execute something locally.
            guard ["http", "https", "mailto", "ftp"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }

        /// T5.6 — denied unless the host is explicitly trusted for it.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard parent.theme.allowRemoteClipboardWrite else { return }
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// T5.6 — clipboard *reads* by a remote host are never permitted.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
