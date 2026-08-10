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

    /// How much scrollback a pane keeps locally.
    ///
    /// Not the same thing as tmux's history: control mode streams `%output` and the emulator on this
    /// side is what holds it, so this is the number that decides whether scrolling up finds anything.
    /// It was never set at all, which meant SwiftTerm's default of 500 lines — about one `ls -R`.
    public var scrollbackLines: Int

    /// Which colour scheme a pane's *content* is drawn in (§7 keeps the chrome on system colours).
    ///
    /// The id rather than the scheme, so the theme stays a small comparable value and the palette
    /// stays in one place. `TerminalColorScheme.named` resolves it, falling back to System for an id
    /// that no longer exists — which is what a downgrade, or a hand-edited preference, produces.
    public var colorSchemeId: String

    public var colorScheme: TerminalColorScheme { TerminalColorScheme.named(colorSchemeId) }

    public static let `default` = TerminalTheme(
        fontName: "SF Mono",
        fontSize: 12,
        ligatures: false,
        scrollbackLines: 10_000,
        colorSchemeId: TerminalColorScheme.system.id
    )

    /// The bounds the settings pane offers, and what ⌘+/⌘− clamp to.
    public static let fontSizeRange: ClosedRange<CGFloat> = 8...32

    /// Roughly what one pane's scrollback costs, for showing beside the setting that decides it.
    ///
    /// P6.7's memory bound is this multiplied by the number of panes, and it is the dominant term by
    /// a distance: a cell is `MemoryLayout<CharData>.stride` bytes — 24 at the time of writing, and
    /// read from SwiftTerm rather than written down here so a dependency bump moves this with it —
    /// so 10 000 lines of an 80-column pane is about 18 MB before anything else exists. The setting
    /// offers 100 000, which is ten times that, *per pane*.
    ///
    /// Deliberately an estimate and deliberately shown as one. It assumes a nominal width because
    /// panes differ and the settings pane cannot know theirs, and it counts cell data only —
    /// allocator rounding, the per-line object and the alternate screen buffer are all real and all
    /// unmodelled, which is why the measured figure is somewhat higher (`docs/measurements.md`).
    /// Its job is to make the difference between 1 000 and 100 000 lines legible at the moment
    /// somebody chooses, not to predict a footprint.
    public func estimatedScrollbackBytesPerPane(columns: Int = 80) -> Int {
        scrollbackLines * columns * MemoryLayout<CharData>.stride
    }

    /// Stops SwiftTerm's parser writing to stdout, which in a debug build it does once per sequence
    /// it does not implement.
    ///
    /// `Terminal.silentLog` defaults to `false` under `#if DEBUG` and `true` otherwise, so this
    /// changes nothing about the packaged app and everything about `swift run`. A remote host whose
    /// shell emits an OSC code SwiftTerm has no case for — a prompt hook is the usual source, and it
    /// fires on every command — otherwise puts a line of parser chatter in the terminal tetmux was
    /// launched from, and in front of `--diagnose`'s own output, which is the one place stdout is
    /// load-bearing.
    ///
    /// Nothing is lost by ignoring the sequence itself: an unhandled OSC is *dropped*, not printed
    /// into the grid, so this is a log that says "a program used a feature we do not have" over and
    /// over. `TETMUX_TERMINAL_LOG=1` puts it back for anyone debugging the emulator, which is the
    /// same env-var shape the measurement probes use.
    public static func quietParserLogging(_ terminal: Terminal) {
        terminal.silentLog = ProcessInfo.processInfo.environment["TETMUX_TERMINAL_LOG"] != "1"
    }

    // MARK: - Persistence

    /// `UserDefaults` rather than a file beside `hosts.json`: this is application preference data,
    /// not part of the user's host configuration, and macOS already has the right place for it.
    private enum Key {
        static let fontName = "terminal.fontName"
        static let fontSize = "terminal.fontSize"
        static let ligatures = "terminal.ligatures"
        static let scrollback = "terminal.scrollbackLines"
        static let colorScheme = "terminal.colorScheme"
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
        if let scheme = defaults.string(forKey: Key.colorScheme) { theme.colorSchemeId = scheme }
        return theme
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(fontName, forKey: Key.fontName)
        defaults.set(Double(fontSize), forKey: Key.fontSize)
        defaults.set(ligatures, forKey: Key.ligatures)
        defaults.set(scrollbackLines, forKey: Key.scrollback)
        defaults.set(colorSchemeId, forKey: Key.colorScheme)
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
    /// T5.6 — this host's opt-in, not an application-wide one. See `HostConfig`.
    let allowsRemoteClipboardWrite: Bool
    let service: SessionService
    let onFocusRequest: () -> Void

    func makeNSView(context: Context) -> TerminalView {
        let view = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), font: theme.resolvedFont())
        view.coordinator = context.coordinator
        view.terminalDelegate = context.coordinator
        // SwiftTerm's macOS view has no options-taking initialiser, so the buffer is made with the
        // default 500 lines and resized here. `changeScrollback` is the supported way to do it after
        // instantiation, and it is what lets the setting apply to panes already on screen rather than
        // only to ones opened afterwards.
        view.getTerminal().changeScrollback(theme.scrollbackLines)
        TerminalTheme.quietParserLogging(view.getTerminal())
        Self.hideReservedScroller(in: view)
        view.allowMouseReporting = true   // T5.3
        view.optionAsMetaKey = true
        Self.applyColors(theme.colorScheme, to: view)

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

    /// Reclaims the gutter SwiftTerm reserves for its scroller, because that gutter silently broke
    /// the geometry contract (§3.3).
    ///
    /// The view keeps `scrollerWidth` — 17pt, and the same for `.overlay` as for `.legacy` — off its
    /// right edge, and derives its own column count from `frame.width - reservedScrollerWidth`,
    /// overriding the `resize(cols:rows:)` we hand it. Meanwhile `requestSizes` measures the
    /// container and asks tmux for `width / cellWidth` columns, subtracting nothing. So tmux sized a
    /// pane to more columns than the emulator could ever draw and every program in it wrapped early:
    /// at 12pt SF Mono the cell is 7.5pt, 17pt of gutter is 2.27 cells, and a 720pt pane asked tmux
    /// for 96 columns while the grid held 93. Anything using the full width — Claude Code's boxes are
    /// the obvious case — spilled its last few columns onto the next line.
    ///
    /// Hiding it rather than subtracting it in `requestSizes`, deliberately. The correction is not a
    /// constant: every pane reserves its own gutter, so it would depend on how many panes are across
    /// the widest row — which is a property of the layout, which is tmux's answer to the size we
    /// asked for. That is a measurement that feeds itself, the same shape as the pane-derived cell
    /// size that made split windows oscillate forever. Hidden, the emulator's usable width is simply
    /// its frame width and the arithmetic has one owner again.
    ///
    /// `reservedScrollerWidth` is `scroller?.isHidden == true ? 0 : scrollerWidth` in SwiftTerm's own
    /// code, so this is a path it supports; the scroller is private, hence reaching it as a subview.
    /// Nothing is lost but the drawn bar: `scrollWheel` is handled by the terminal view itself and
    /// never consults it.
    static func hideReservedScroller(in view: TerminalView) {
        for case let scroller as NSScroller in view.subviews {
            scroller.isHidden = true
        }
    }

    /// Paints one pane in a scheme, or hands it back to the system.
    ///
    /// The System scheme is not a palette of its own: `configureNativeColors` sets the view from
    /// `NSColor.textColor` and `.textBackgroundColor`, which follow light and dark and change under
    /// the app while it runs. A scheme that copied today's values into fixed ones would look right
    /// until the user switched appearance.
    ///
    /// `installColors` before the foreground and background, because it resets the view's colour
    /// cache — setting them first would have them thrown away.
    static func applyColors(_ scheme: TerminalColorScheme, to view: TerminalView) {
        guard !scheme.followsSystemAppearance else {
            view.installColors(TerminalColorScheme.defaultAnsi.map(\.terminalColor))
            view.configureNativeColors()
            view.caretColor = NSColor.textColor
            return
        }
        view.installColors(scheme.ansi.map(\.terminalColor))
        view.nativeForegroundColor = scheme.foreground.nsColor
        view.nativeBackgroundColor = scheme.background.nsColor
        view.caretColor = scheme.cursor.nsColor
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self
        // Cheap, and it keeps the gutter reclaimed if SwiftTerm ever rebuilds the scroller — the
        // failure it guards against is silent and only visible as text wrapping a few columns early.
        Self.hideReservedScroller(in: view)

        if view.font.fontName != theme.resolvedFont().fontName || view.font.pointSize != theme.fontSize {
            view.font = theme.resolvedFont()
        }

        let terminalForOptions = view.getTerminal()
        if terminalForOptions.options.scrollback != theme.scrollbackLines {
            terminalForOptions.changeScrollback(theme.scrollbackLines)
        }

        // Re-applied on every update rather than only at creation, for the same reason scrollback is:
        // a pane already on screen has to take the new scheme, and panes are never rebuilt (their
        // `.id(paneId)` is what keeps their scrollback). Guarded on a change because `installColors`
        // discards the view's 256-entry colour cache and repaints everything.
        if context.coordinator.appliedSchemeId != theme.colorSchemeId {
            context.coordinator.appliedSchemeId = theme.colorSchemeId
            Self.applyColors(theme.colorScheme, to: view)
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
        /// The scheme this pane is currently painted in, so `updateNSView` can tell a real change
        /// from the dozens of updates a state broadcast produces. Re-installing a palette on each
        /// one would repaint every pane on every `%layout-change`.
        var appliedSchemeId: String = TerminalColorScheme.system.id

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

        /// P6.4's batching: bytes that have arrived within the current display frame and have not
        /// been handed to the emulator yet. Never a hole in the stream — everything here is fed, in
        /// order, on the next frame.
        private var pendingOutput: [UInt8] = []
        private var frameLink: CADisplayLink?
        private var lastHandoff: CFTimeInterval = 0
        /// The compositor's answer, once the link is running; 1/60 until then, which is the
        /// conservative guess — a longer assumed frame means *more* immediate handoffs, never a
        /// keystroke held back.
        private var frameInterval: CFTimeInterval = 1.0 / 60
        /// Consecutive frames with nothing to flush. The link is stopped after a few, because a pane
        /// is usually idle and twenty panes each holding a permanent per-frame callback is the shape
        /// of problem P6.6 exists to prevent.
        private var idleFrames = 0
        private var unacknowledged = 0
        private var flowControl: (hostId: String, paneId: String, subscriber: UUID, service: SessionService)?

        func attach(view: TerminalView, hostId: String, paneId: String, service: SessionService) {
            self.view = view
            subscription?.cancel()
            subscription = Task { [weak self] in
                let subscription = await service.subscribeToPane(hostId: hostId, paneId: paneId)
                self?.flowControl = (hostId, paneId, subscription.id, service)
                // Feeding happens here, on the main actor, so this loop *is* the paint rate.
                for await data in subscription.stream {
                    if Task.isCancelled { break }
                    guard let self, let view = self.view else { break }
                    let bytes = [UInt8](data)
                    // P6.1's middle point, before the emulator sees the bytes: this is the round
                    // trip landing. Guarded inside the probe, which is off unless a measurement
                    // asked for it — the scan would otherwise be on the path P6.3 measures.
                    LatencyProbe.shared.observeOutput(bytes)
                    self.hand(bytes, to: view)
                }
            }
        }

        /// P6.4 — one handoff per display frame, and the first one after a quiet moment immediately.
        ///
        /// The edge is the whole design, and it is the lesson the keystroke coalescer already paid
        /// for: batching on the *trailing* edge makes every event with nothing to share wait out a
        /// window, which at typing speed is every event. So a chunk arriving into an empty buffer
        /// more than a frame after the last handoff is fed at once — an echoed keystroke never waits
        /// — and everything that arrives during the frame that follows is coalesced into one feed on
        /// the next one. Under continuous output that is one handoff per frame, which is what the
        /// requirement asks for; at a prompt it is one per keystroke, which is what P6.1 needs.
        ///
        /// Order is preserved by the `isEmpty` half of the condition: once anything is buffered,
        /// everything after it buffers too, so nothing overtakes what is waiting.
        private func hand(_ bytes: [UInt8], to view: TerminalView) {
            let now = CACurrentMediaTime()
            if pendingOutput.isEmpty, now - lastHandoff >= frameInterval {
                lastHandoff = now
                feed(bytes, to: view)
                return
            }
            pendingOutput.append(contentsOf: bytes)
            startFrameLink(on: view)
        }

        private func feed(_ bytes: [UInt8], to view: TerminalView) {
            view.feed(byteArray: bytes[...])
            // Acknowledged where it is *fed* rather than where it arrives, which is what P6.5's
            // accounting means by it: the service is asking whether this viewer is keeping up, and
            // bytes sitting in `pendingOutput` have not been drawn by anybody.
            unacknowledged += bytes.count
            guard unacknowledged >= acknowledgeAfterBytes, let flow = flowControl else { return }
            let bytesToReport = unacknowledged
            unacknowledged = 0
            Task { await flow.service.acknowledge(
                hostId: flow.hostId, paneId: flow.paneId,
                subscriber: flow.subscriber, bytes: bytesToReport
            ) }
        }

        /// A scheduled `CADisplayLink` **retains its target**, so while this is running the run loop
        /// is holding the coordinator alive. `detach` is what normally ends it — `dismantleNSView`
        /// calls it — and the idle stop is the backstop: a pane that goes quiet drops the link, and
        /// with it the retain, within a couple of hundred milliseconds. It cannot be undone from
        /// `deinit`, which is nonisolated and cannot reach any of this.
        private func startFrameLink(on view: TerminalView) {
            idleFrames = 0
            guard frameLink == nil else { return }
            let link = view.displayLink(target: self, selector: #selector(flushFrame(_:)))
            link.add(to: .main, forMode: .common)
            frameLink = link
        }

        @objc private func flushFrame(_ link: CADisplayLink) {
            frameInterval = link.targetTimestamp - link.timestamp
            guard let view, !pendingOutput.isEmpty else {
                idleFrames += 1
                if idleFrames > 12 { stopFrameLink() }
                return
            }
            idleFrames = 0
            let batch = pendingOutput
            pendingOutput.removeAll(keepingCapacity: true)
            lastHandoff = CACurrentMediaTime()
            feed(batch, to: view)
        }

        private func stopFrameLink() {
            frameLink?.invalidate()
            frameLink = nil
        }

        func detach() {
            subscription?.cancel()
            subscription = nil
            stopFrameLink()
            // Anything still buffered is dropped, and that is safe for the one reason it is ever
            // safe here: the view is going away, and whatever replaces it repaints from
            // `capture-pane`. A pane that stays on screen never reaches this.
            pendingOutput.removeAll()
            view = nil
        }

        /// The pane's own paste, for the routes that do not go through the Edit menu — the context
        /// menu and middle-click. It targets *this* pane rather than `activeScope`'s, because a
        /// right-click is a statement about where the pointer is and need not have focused anything.
        func pasteFromPasteboard() {
            paste(NSPasteboard.general.string(forType: .string))
        }

        /// Middle-click's text: the selection, the way it is on every X11 terminal.
        ///
        /// This pane's own selection first, then the last selection made in *any* pane, which is
        /// what makes select-here/paste-there work and is the whole of what a primary selection is.
        /// The clipboard is the last resort and only applies when nothing has ever been selected —
        /// it used to be the *first* answer, so selecting a word and middle-clicking pasted whatever
        /// was last ⌘C'd instead, which is a silent wrong paste rather than a missing feature.
        func pasteSelection(in view: TerminalView) {
            paste(view.getSelection() ?? PrimarySelection.text ?? NSPasteboard.general.string(forType: .string))
        }

        private func paste(_ text: String?) {
            guard let text, !text.isEmpty else { return }
            let hostId = parent.hostId
            let paneId = parent.paneId
            let service = parent.service
            parent.onFocusRequest()
            Task { await service.paste(hostId: hostId, paneId: paneId, text: text) }
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

        /// T5.5 — hyperlinks open in the default handler, ⌘-clicked.
        ///
        /// Reached for OSC 8 payloads *and* for URLs SwiftTerm found in plain text, which is what
        /// makes the address `git push` prints clickable. Both arrive here as a string and are held
        /// to the same scheme allowlist; nothing about the route they took gets them any more trust.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            TerminalPaneView.openExternalLink(link)
        }

        /// T5.6 — denied unless *this host* is explicitly trusted for it.
        ///
        /// The gate used to be a `TerminalTheme` field with no persistence key, no control anywhere
        /// in the app and no way to become true, so its own doc comment's "unless the user opts in
        /// per host" described something that did not exist. It is a `HostConfig` field now, which
        /// is the only shape the promise can actually take: trusting the machine on your desk to set
        /// your clipboard is a different decision from trusting a shared box you ssh into.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard parent.allowsRemoteClipboardWrite else { return }
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// T5.6 — clipboard *reads* by a remote host are never permitted.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }

    /// The one place that decides a link off the wire is safe to hand to the system.
    ///
    /// A pane's contents are remote text, and `NSWorkspace.open` will happily launch whatever
    /// application has claimed a scheme — `file:`, `ssh:`, or anything a third-party app registered.
    /// So the allowlist is schemes that cannot start something locally, and it is applied to OSC 8
    /// payloads and to plain-text matches alike.
    @MainActor
    static func openExternalLink(_ link: String) {
        guard isOpenableExternally(link), let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Split out from `openExternalLink` so the policy can be asserted without launching anything.
    static func isOpenableExternally(_ link: String) -> Bool {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp"].contains(scheme)
    }
}

/// A terminal view that honours the `replacementRange` the input system hands `insertText`.
///
/// macOS press-and-hold — holding `n` for `ñ`, `e` for `è` — is not a composition: the base
/// character is inserted *immediately*, and the accent picked from the popup arrives as a second
/// `insertText` carrying a range covering the first. Verified against a logging `NSTextInputClient`:
///
///     insertText 'n'  replacementRange={NSNotFound, 0}
///     …popup; the repeat events produce no insertText at all…
///     insertText 'ñ'  replacementRange={0, 1}
///
/// SwiftTerm discards that range, so both characters reached the pane and the user typed `nñ`.
/// There is no way to hold the base character back and find out: nothing distinguishes the first
/// `insertText` of a long press from an ordinary keystroke, so deferring would mean deferring every
/// keystroke, which is P6.1's whole budget spent on a feature almost nobody uses.
///
/// So the replacement is honoured the only way a terminal can honour one — by asking the program to
/// erase what it was already sent. `0x7f` is what SwiftTerm sends for the Delete key, so this is the
/// same byte the pane would receive if the user had erased the character by hand; choosing `0x08`
/// here would be a second, quieter answer to a question the emulator has already settled.
///
/// It is a base class rather than something on `PaneTerminalView` because §4.6's passthrough surface
/// is a `TerminalView` too and has the same input system in front of it.
class ComposingTerminalView: TerminalView {
    /// What the last `insertText` was given, so a replacement knows how many characters — rather
    /// than how many UTF-16 units — it is being asked to take back.
    private var lastInsertedText: String?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSString) as String? ?? (string as? NSAttributedString)?.string
        if replacementRange.length > 0 {
            send(Array(repeating: 0x7f, count: erasures(replacing: replacementRange.length)))
        }
        lastInsertedText = text
        super.insertText(string, replacementRange: replacementRange)
    }

    /// How many Deletes take back `units` UTF-16 units of what we last sent.
    ///
    /// The two counts differ for anything outside the BMP, and the pane counts characters — so the
    /// text we actually sent is the better answer whenever the range is exactly it, which for a
    /// press-and-hold it always is. When it is not, the input system's count is all there is to go
    /// on: it is the number of units it believes this client is holding.
    private func erasures(replacing units: Int) -> Int {
        guard let lastInsertedText, lastInsertedText.utf16.count == units else { return units }
        return lastInsertedText.count
    }
}

/// The pane surface, with the three things a terminal is expected to do with a mouse that SwiftTerm
/// leaves to its host: a context menu, opening what is under the pointer, and middle-click paste.
///
/// A subclass rather than a gesture layered on top, for the same reason `PaneDivider` is an
/// `NSView`: this view tracks the mouse for selection, and a SwiftUI gesture over it never sees an
/// event whatever the z-order says.
final class PaneTerminalView: ComposingTerminalView, NSMenuItemValidation {
    weak var coordinator: TerminalPaneView.Coordinator?

    /// SwiftTerm's own cell size, read back rather than recomputed.
    ///
    /// `getOptimalFrameSize()` is `cellDimension × grid + reservedScrollerWidth`, and the scroller is
    /// hidden here so that last term is zero — which makes this the emulator's real `cellDimension`
    /// with no second implementation to drift from it. Mirroring the font arithmetic instead would
    /// mean resolving the backing scale factor the same way SwiftTerm does, and getting that wrong
    /// moves the cell width by a whole point and the hit column by several.
    private var cellDimension: CGSize? {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }
        let optimal = getOptimalFrameSize().size
        guard optimal.width > 0, optimal.height > 0 else { return nil }
        return CGSize(
            width: optimal.width / CGFloat(terminal.cols),
            height: optimal.height / CGFloat(terminal.rows)
        )
    }

    /// The link under a point in view coordinates, explicit or found in plain text.
    ///
    /// `.screen` coordinates, so the lookup follows the viewport when the user has scrolled back —
    /// the row is relative to what is displayed, and SwiftTerm adds `yDisp` itself.
    private func link(at point: CGPoint) -> String? {
        guard let cell = cellDimension else { return nil }
        let terminal = getTerminal()
        let col = Int(point.x / cell.width)
        let row = Int((bounds.height - point.y) / cell.height)
        guard col >= 0, col < terminal.cols, row >= 0, row < terminal.rows else { return nil }
        return terminal.link(at: .screen(Position(col: col, row: row)), mode: .explicitAndImplicit)
    }

    /// What the right-click landed on, captured at menu-build time.
    ///
    /// The menu outlives the event, and by the time an item fires the pointer has moved and the pane
    /// may have scrolled under it, so re-deriving the link from the cursor would open whatever
    /// happens to be there now.
    private var linkUnderCursor: String?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        linkUnderCursor = link(at: point)

        let menu = NSMenu()
        // AppKit adds Services and text plug-ins — AutoFill, Look Up — to a context menu on a view
        // that accepts text input, which this one does because it is the keyboard's destination.
        // They are aimed at an editable field and none of them means anything over a remote pane.
        menu.allowsContextMenuPlugIns = false
        if let link = linkUnderCursor {
            menu.addItem(withTitle: "Open \(Self.abbreviate(link))", action: #selector(openLinkUnderCursor), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Copy Link", action: #selector(copyLinkUnderCursor), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Copy", action: #selector(copySelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste", action: #selector(pasteIntoPane), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// Enough of a URL to tell two apart, without a menu item as wide as the screen.
    private static func abbreviate(_ link: String, limit: Int = 48) -> String {
        link.count <= limit ? link : link.prefix(limit - 1) + "…"
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copySelection):
            return !(getSelection() ?? "").isEmpty
        case #selector(copyLinkUnderCursor), #selector(openLinkUnderCursor):
            return linkUnderCursor != nil
        case #selector(pasteIntoPane):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }

    @objc private func openLinkUnderCursor() {
        guard let link = linkUnderCursor else { return }
        TerminalPaneView.openExternalLink(link)
    }

    @objc private func copyLinkUnderCursor() {
        guard let link = linkUnderCursor else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    @objc private func copySelection() {
        copy(self)
    }

    /// Paste goes through `SessionService`, never through SwiftTerm's own `paste(_:)`.
    ///
    /// SwiftTerm's inserts the text as *keystrokes*, which here means one `send-keys` per character —
    /// the path whose own comment says a megabyte of it wedges the channel, and which cannot carry a
    /// newline safely. The service builds a tmux buffer instead, chunked and double-quoted.
    @objc private func pasteIntoPane() {
        coordinator?.pasteFromPasteboard()
    }

    // MARK: - Accessibility

    /// What is on the screen, which is what a screen reader is asking for.
    ///
    /// SwiftTerm's own accessibility service is an empty stub, so a pane was an element with a name,
    /// a role and nothing to read — every piece of chrome around the terminal was announced and the
    /// terminal was silent. This is the visible viewport only: bounded by the grid rather than by the
    /// scrollback, so it stays cheap however much history the pane is holding, and it is what
    /// "read the window" should mean for a terminal in any case.
    ///
    /// Still missing, and the reason the TODO entry stays open: nothing posts `.valueChanged`, so
    /// output that arrives while VoiceOver is idle is not announced — the user has to go back and
    /// read. Announcing it properly means diffing for the lines that are new, because re-reading the
    /// whole screen on every chunk of a build log is worse than saying nothing.
    override func accessibilityValue() -> Any? {
        visibleText()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        visibleText().count
    }

    override func accessibilitySelectedText() -> String? {
        let selected = getSelection() ?? ""
        return selected.isEmpty ? nil : selected
    }

    /// VoiceOver otherwise announces "text area", which is true of every field on screen.
    override func accessibilityRoleDescription() -> String? {
        "terminal"
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        getTerminal().getCursorLocation().y
    }

    private func visibleText() -> String {
        let terminal = getTerminal()
        return (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// Middle-click pastes the **selection**, the way it does everywhere else a terminal is used.
    ///
    /// It used to paste the clipboard, on the reasoning that macOS has no primary selection so
    /// there was nothing else it could mean. There is: the terminal's own selection, which is what
    /// every X11 terminal pastes here and what Terminal.app pastes too. Reading the clipboard
    /// instead meant selecting a word and middle-clicking quietly pasted whatever was last ⌘C'd —
    /// not a missing feature but a wrong paste, into a shell, with no way to tell from the gesture.
    ///
    /// It routes through the same chunked path as ⌘V rather than SwiftTerm's keystroke paste, so a
    /// multi-line selection cannot arrive as tmux commands.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        coordinator?.pasteSelection(in: self)
    }

    /// Records every selection as the app-wide primary, so select-here/paste-there works across
    /// panes and tabs the way it does across windows on X11.
    ///
    /// `selection` itself is internal to SwiftTerm, so this is the only seam: `selectionChanged` is
    /// `open` and `getSelection()` is public. A cleared selection is deliberately *not* recorded —
    /// releasing a drag or pressing a key clears it, and a primary that emptied itself the moment
    /// you reached for the mouse would be useless.
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if let text = getSelection(), !text.isEmpty { PrimarySelection.text = text }
    }
}

/// The last text selected in any pane — X11's PRIMARY, kept by hand because macOS has no such
/// pasteboard and SwiftTerm has no cross-view notion of one.
///
/// Deliberately not `NSPasteboard`: this must not touch the user's clipboard, and it must not
/// outlive the process either. A selection is a transient pointing gesture, not a document.
@MainActor
enum PrimarySelection {
    static var text: String?
}
