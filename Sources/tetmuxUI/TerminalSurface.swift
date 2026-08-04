import AppKit
import SwiftTerm
import SwiftUI
import tetmuxCore

extension ClosedRange where Bound == CGFloat {
    func clamping(_ value: CGFloat) -> CGFloat { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// User-visible terminal appearance. Kept in one place so the settings pane has a single thing to
/// write to, and so both backends behind `TerminalSurface` would read the same values.
public struct TerminalTheme: Equatable, Sendable {
    public var fontName: String
    public var fontSize: CGFloat
    /// T5.8 — ligatures off by default.
    public var ligatures: Bool
    /// T5.6 — a remote host silently overwriting the local clipboard is an injection vector, so
    /// OSC 52 writes are denied unless the user opts in per host. Reads are never permitted.
    public var allowRemoteClipboardWrite: Bool

    /// How much scrollback a pane keeps locally.
    ///
    /// Not the same thing as tmux's history: control mode streams `%output` and the emulator on this
    /// side is what holds it, so this is the number that decides whether scrolling up finds anything.
    /// It was never set at all, which meant SwiftTerm's default of 500 lines — about one `ls -R`.
    public var scrollbackLines: Int

    public static let `default` = TerminalTheme(
        fontName: "SF Mono",
        fontSize: 12,
        ligatures: false,
        allowRemoteClipboardWrite: false,
        scrollbackLines: 10_000
    )

    /// The bounds the settings pane offers, and what ⌘+/⌘− clamp to.
    public static let fontSizeRange: ClosedRange<CGFloat> = 8...32

    // MARK: - Persistence

    /// `UserDefaults` rather than a file beside `hosts.json`: this is application preference data,
    /// not part of the user's host configuration, and macOS already has the right place for it.
    private enum Key {
        static let fontName = "terminal.fontName"
        static let fontSize = "terminal.fontSize"
        static let ligatures = "terminal.ligatures"
        static let scrollback = "terminal.scrollbackLines"
    }

    public static func load(from defaults: UserDefaults = .standard) -> TerminalTheme {
        var theme = TerminalTheme.default
        if let name = defaults.string(forKey: Key.fontName) { theme.fontName = name }
        // `double(forKey:)` answers 0 for a key that was never written, which is not a font size.
        let size = defaults.double(forKey: Key.fontSize)
        if size > 0 { theme.fontSize = fontSizeRange.clamping(CGFloat(size)) }
        if defaults.object(forKey: Key.ligatures) != nil {
            theme.ligatures = defaults.bool(forKey: Key.ligatures)
        }
        let scrollback = defaults.integer(forKey: Key.scrollback)
        if scrollback > 0 { theme.scrollbackLines = scrollback }
        return theme
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(fontName, forKey: Key.fontName)
        defaults.set(Double(fontSize), forKey: Key.fontSize)
        defaults.set(ligatures, forKey: Key.ligatures)
        defaults.set(scrollbackLines, forKey: Key.scrollback)
    }

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
    /// Applies the font-size bounds. Written here so the slider, the menu commands, and the values
    /// read back from `UserDefaults` cannot disagree about what a legal size is.
    public static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        fontSizeRange.clamping(size)
    }

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
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), font: theme.resolvedFont())
        view.terminalDelegate = context.coordinator
        // SwiftTerm's macOS view has no options-taking initialiser, so the buffer is made with the
        // default 500 lines and resized here. `changeScrollback` is the supported way to do it after
        // instantiation, and it is what lets the setting apply to panes already on screen rather than
        // only to ones opened afterwards.
        view.getTerminal().changeScrollback(theme.scrollbackLines)
        view.allowMouseReporting = true   // T5.3
        view.optionAsMetaKey = true
        view.configureNativeColors()

        // The pane is the terminal, and VoiceOver had nothing at all to say about it — SwiftTerm's
        // own accessibility service is an empty stub, so every piece of chrome around the pane was
        // announced and the pane itself was silent. This does not make the grid navigable, but it
        // does mean the element has a name and a role instead of being invisible.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(NSAccessibility.Role.textArea)
        view.setAccessibilityLabel("Terminal pane \(paneId)")

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

        let terminalForOptions = view.getTerminal()
        if terminalForOptions.options.scrollback != theme.scrollbackLines {
            terminalForOptions.changeScrollback(theme.scrollbackLines)
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
        /// F4.31 — a bell from a pane nobody is looking at is worth a notification, not just a beep.
        ///
        /// The beep alone was the whole handler, and a beep is useless in the case that matters: the
        /// long build finishing in a background window, which is the reason a terminal rings at all.
        /// The notification is posted only when the app is not frontmost, because a banner for a pane
        /// the user is watching is noise.
        func bell(source: TerminalView) {
            NSSound.beep()
            guard !NSApp.isActive else { return }
            BellNotifier.shared.post(paneId: parent.paneId)
        }

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
