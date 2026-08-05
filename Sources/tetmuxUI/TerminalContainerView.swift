import SwiftUI
import tetmuxCore

/// Renders one tmux window: its pane tree as nested splits, sized as tmux reported.
///
/// Two rules keep this correct, and both were violated by the arrangement that showed nothing:
///
/// 1. **Identity is explicit.** A pane's surface is keyed by its pane id, so a `%layout-change` or
///    any other state broadcast reuses the existing `NSView` instead of building a new one.
///    Rebuilding it throws away the emulator's grid, which is exactly what "the terminals are not
///    rendered" looks like from the outside.
/// 2. **Geometry flows one way.** The container measures itself, asks tmux for a client size, then
///    lays out whatever tmux sends back. No surface resizes ahead of tmux's confirmation (§3.3).
public struct TerminalContainerView: View {
    let hostId: String
    let window: TmuxWindow
    let theme: TerminalTheme
    let service: SessionService
    @Binding var focusedPaneId: String?
    /// Identity of the macOS window this container lives in.
    ///
    /// A tmux window has one size, so when the same window is on screen twice only one of the two
    /// containers can drive it. The owner is whichever one has focus; the other renders the grid tmux
    /// gave the owner (§3.3 — tmux is still authoritative, we just stop arguing about what to ask for).
    let owner: UUID
    /// Whether this container also reports the *client's* size. Only the main window does: below tmux
    /// 2.9 there is no per-window sizing at all, and `refresh-client -C` is then the single knob for
    /// every window the client shows — two windows setting it would just overwrite each other.
    let drivesClientSize: Bool
    /// T5.6 — whether *this host* may write the Mac's clipboard with OSC 52. Passed down from the
    /// host's config rather than read from the theme: it is a statement about one machine's
    /// trustworthiness, and the theme is application-wide.
    let allowsRemoteClipboardWrite: Bool
    /// R3.7 — the macOS window's live-resize gate. Held rather than read: sizing requests made while
    /// the user is dragging an edge are deferred to the size they let go of (see `LiveResizeGate`).
    let liveResize: LiveResizeGate

    /// Divider thickness between splits, in points.
    private let dividerWidth: CGFloat = 1
    /// How wide the *draggable* part of a divider is. The seam stays one point; this is the target.
    private let grabWidth: CGFloat = 9

    @State private var containerSize: CGSize = .zero
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var contrast

    /// Pixel density of the display **this window** is on, for snapping the cell size to whole pixels
    /// the way SwiftTerm does.
    ///
    /// From the environment, and it has to be: `NSScreen.main` is not the window's screen, it is the
    /// screen holding whichever window has keyboard focus *anywhere on the system*. With a 1× monitor
    /// beside a 2× built-in display, clicking into another app on the other screen changes the answer
    /// while this window has not moved — so the two sides of the geometry contract come apart, since
    /// SwiftTerm resolves its own `cellDimension` from `window?.backingScaleFactor` and gets the real
    /// one. Measured: 12pt SF Mono advances `W` by 7.2, which snaps to 7.5 at 2× and 8.0 at 1×, and a
    /// 572pt pane on the Retina display asked tmux for 71 columns while its grid drew 76 — five dead
    /// columns tmux never writes into. The other way round it is the early-wrapping failure that the
    /// reserved-scroller gutter used to cause.
    ///
    /// `\.displayScale` follows the window between displays, which `NSScreen.main` read from a
    /// background application does not do reliably at all.
    @Environment(\.displayScale) private var backingScaleFactor

    public init(
        hostId: String,
        window: TmuxWindow,
        theme: TerminalTheme = .default,
        service: SessionService,
        focusedPaneId: Binding<String?>,
        owner: UUID,
        drivesClientSize: Bool = true,
        allowsRemoteClipboardWrite: Bool = false,
        liveResize: LiveResizeGate
    ) {
        self.liveResize = liveResize
        self.hostId = hostId
        self.window = window
        self.theme = theme
        self.service = service
        self._focusedPaneId = focusedPaneId
        self.owner = owner
        self.drivesClientSize = drivesClientSize
        self.allowsRemoteClipboardWrite = allowsRemoteClipboardWrite
    }

    public var body: some View {
        GeometryReader { proxy in
            content(in: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onAppear { updateContainerSize(proxy.size) }
                .onChange(of: proxy.size) { _, newValue in updateContainerSize(newValue) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Taking focus takes over sizing, so the window in front is the one that fits.
        .onChange(of: controlActiveState) { _, state in
            guard state == .key else { return }
            claimSize()
        }
        .onAppear { if controlActiveState == .key { claimSize() } }
        // Dragging a window to a display of a different density changes the *cell* size without
        // changing the container's size in points, so nothing else here would notice: `requestSizes`
        // hangs off `proxy.size`, which is identical before and after the move. Without this the
        // panes keep the grid they were given for the old display until something unrelated resizes
        // them — which, on a desk with a 1× monitor beside a 2× laptop, is most of the time.
        .onChange(of: backingScaleFactor) { _, _ in requestSizes() }
        .onDisappear {
            let (hostId, windowId, owner) = (self.hostId, window.id, self.owner)
            // A request held for a container that has gone away would be sent when the drag ends,
            // resizing a tmux window on behalf of a view that no longer exists.
            liveResize.cancel(key: windowId)
            Task { await service.releaseWindowSize(hostId: hostId, windowId: windowId, owner: owner) }
        }
    }

    private func claimSize() {
        let (hostId, windowId, owner) = (self.hostId, window.id, self.owner)
        Task {
            await service.claimWindowSize(hostId: hostId, windowId: windowId, owner: owner)
            requestSizes()
        }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        // `renderTree`, not `layoutTree`: while a pane is zoomed those differ, and tmux is emitting
        // output sized to the visible one.
        if let tree = window.renderTree {
            node(tree, size: size)
                // Every divider in one layer above the whole tree, rather than each inside the
                // container it belongs to. Nesting them put a handle underneath the pane surfaces of
                // its *sibling* subtree — the outermost split was draggable and the nested one was
                // not, silently. One overlay makes the z-order a single fact instead of a per-branch
                // accident.
                .overlay(alignment: .topLeading) { dividerOverlay(tree, size: size) }
        } else if let paneId = window.preferredPaneId {
            // Layout has not arrived yet — show the active pane full-bleed rather than nothing.
            pane(paneId, cols: 80, rows: 24)
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for tmux layout…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Lays a layout node into `size`, splitting proportionally by the cell dimensions tmux chose
    /// (F4.7), so a 70/30 split on the server is a 70/30 split on screen.
    private func node(_ node: LayoutNode, size: CGSize) -> AnyView {
        switch node {
        case .leaf(let paneId, let cols, let rows, _, _):
            return AnyView(pane(paneId, cols: cols, rows: rows))

        case .container(let direction, _, _, _, _, let children):
            let isRow = direction == .leftRight
            let dividers = dividerWidth * CGFloat(max(children.count - 1, 0))
            let available = max((isRow ? size.width : size.height) - dividers, 1)
            let weights = children.map { isRow ? $0.width : $0.height }
            let extents = Self.distribute(available, among: weights)

            let stack = ZStack(alignment: .topLeading) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    let extent = extents[index]
                    let offset = extents[..<index].reduce(0, +) + dividerWidth * CGFloat(index)
                    let childSize = isRow
                        ? CGSize(width: extent, height: size.height)
                        : CGSize(width: size.width, height: extent)

                    self.node(child, size: childSize)
                        .frame(width: childSize.width, height: childSize.height, alignment: .topLeading)
                        .offset(x: isRow ? offset : 0, y: isRow ? 0 : offset)
                }

            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .separatorColor))

            return AnyView(stack)
        }
    }

    /// One draggable boundary: where it is, which pane setting its size moves it, and from what.
    private struct DividerSpec: Identifiable {
        let id: String
        let isRow: Bool
        let rect: CGRect
        let baseCells: Int
        let targetPaneId: String
    }

    @ViewBuilder
    private func dividerOverlay(_ tree: LayoutNode, size: CGSize) -> some View {
        let cell = theme.cellSize(backingScaleFactor: backingScaleFactor)
        ZStack(alignment: .topLeading) {
            ForEach(dividers(tree, origin: .zero, size: size, path: "")) { spec in
                PaneDivider(
                    isRow: spec.isRow,
                    baseCells: spec.baseCells,
                    cellExtent: spec.isRow ? cell.width : cell.height
                ) { cells in
                    resize(paneId: spec.targetPaneId, isRow: spec.isRow, toCells: cells)
                }
                .frame(width: spec.rect.width, height: spec.rect.height)
                .offset(x: spec.rect.minX, y: spec.rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Walks the layout with exactly the arithmetic `node(_:size:)` uses, so the handles land on the
    /// seams rather than near them.
    private func dividers(
        _ node: LayoutNode, origin: CGPoint, size: CGSize, path: String
    ) -> [DividerSpec] {
        guard case .container(let direction, _, _, _, _, let children) = node else { return [] }
        let isRow = direction == .leftRight
        let gaps = dividerWidth * CGFloat(max(children.count - 1, 0))
        let available = max((isRow ? size.width : size.height) - gaps, 1)
        let weights = children.map { isRow ? $0.width : $0.height }
        let extents = Self.distribute(available, among: weights)

        var specs: [DividerSpec] = []
        for (index, child) in children.enumerated() {
            let offset = extents[..<index].reduce(0, +) + dividerWidth * CGFloat(index)
            let childOrigin = isRow
                ? CGPoint(x: origin.x + offset, y: origin.y)
                : CGPoint(x: origin.x, y: origin.y + offset)
            let childSize = isRow
                ? CGSize(width: extents[index], height: size.height)
                : CGSize(width: size.width, height: extents[index])
            specs += dividers(child, origin: childOrigin, size: childSize, path: "\(path).\(index)")

            // The boundary *before* this child, owned by the child ahead of it.
            guard index > 0, let paneId = children[index - 1].paneIds.first else { continue }
            let boundary = extents[..<index].reduce(0, +) + dividerWidth * CGFloat(index - 1)
            let inset = (grabWidth - dividerWidth) / 2
            let rect = isRow
                ? CGRect(x: origin.x + boundary - inset, y: origin.y, width: grabWidth, height: size.height)
                : CGRect(x: origin.x, y: origin.y + boundary - inset, width: size.width, height: grabWidth)
            // Identity is the seam's *place in the tree*, and deliberately nothing else.
            //
            // Not the target pane: a left/right seam and the top/bottom seam just inside its leading
            // column both resolve to that column's first pane, and two specs with one identity means
            // `ForEach` renders one of them — one draggable seam where there should be two.
            //
            // And not the position either, tempting as it is. The position changes the instant a drag
            // resizes anything, which changes the identity, which makes SwiftUI tear the view down and
            // build a new one mid-gesture — so the drag died after a single cell and the pane moved
            // one column however far the pointer went.
            specs.append(DividerSpec(
                id: "\(path).\(index)|\(isRow ? "v" : "h")",
                isRow: isRow, rect: rect,
                baseCells: weights[index - 1], targetPaneId: paneId
            ))
        }
        return specs
    }

    /// Asks tmux to make `child` `cells` wide or tall.
    ///
    /// §3.3 as everywhere else: this only *asks*. Nothing on screen moves until `%layout-change` comes
    /// back, so a resize tmux refuses — dragging past a pane's minimum, say — simply does not happen
    /// rather than leaving the view disagreeing with the server.
    ///
    /// Targets the first pane inside the child, which is enough for either orientation: in a
    /// left/right split every pane of a child spans the child's full width, and in a top/bottom split
    /// every pane spans its full height, so setting one pane's extent moves the boundary itself.
    private func resize(paneId: String, isRow: Bool, toCells cells: Int) {
        guard cells >= 1 else { return }
        let (hostId, service) = (self.hostId, self.service)
        Task {
            await service.resizePane(
                hostId: hostId, paneId: paneId,
                cols: isRow ? cells : nil,
                rows: isRow ? nil : cells
            )
        }
    }

    /// Splits `available` points across children weighted by their cell counts, giving the rounding
    /// remainder to the last child so the parts always sum to exactly the whole.
    static func distribute(_ available: CGFloat, among weights: [Int]) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: available / CGFloat(weights.count), count: weights.count)
        }
        var result: [CGFloat] = []
        var used: CGFloat = 0
        for weight in weights.dropLast() {
            let extent = max((available * CGFloat(weight) / CGFloat(total)).rounded(), 1)
            result.append(extent)
            used += extent
        }
        result.append(max(available - used, 1))
        return result
    }

    /// How far an unfocused pane drops back when the window is split.
    ///
    /// Raised twice now, and for the same reason each time: the frame around the focused pane is what
    /// answers "which one am I typing into", so the other panes only have to be *quieter* than it, not
    /// hard to read. At 0.54 black-on-white text composited to about `#75757a` — legible in isolation
    /// but noticeably washed out beside the focused pane, and the panes you are not typing into are
    /// usually still the ones you are watching, which is the whole reason the window is split. This
    /// puts them near `#474747`: clearly recessive, still comfortably readable.
    ///
    /// This is a composite rather than a foreground colour on the emulator, which is what the spec's
    /// wording asks for and SwiftTerm cannot honestly give: `nativeForegroundColor` recolours only text
    /// the program left at the default, so a pane running `ls --color` or an editor would not dim at
    /// all, and setting it repaints nothing already on screen.
    private static let inactivePaneOpacity: Double = 0.72

    /// The active pane's frame: the accent with most of its saturation taken out, so it sits below the
    /// pane's own text in contrast rather than competing with it.
    ///
    /// Saturation and not opacity, which is the distinction the spec is drawing and the one that is easy
    /// to get wrong. Fading the accent toward the pane's ground only *lightens* it — the blue channel
    /// stays pinned at full, so the result is a pale accent rather than a desaturated one, and it still
    /// reads as coloured. Cutting saturation instead reaches the sketch's `#a8c4e8` almost exactly.
    ///
    /// Derived from `controlAccentColor` rather than written down as that hex, for the reason the
    /// sidebar avoids literal fills: the accent is the user's choice, and desaturating whatever they
    /// picked is right for a graphite or pink accent where a hardcoded blue is simply wrong. The dynamic
    /// provider re-resolves it per appearance, so dark mode gets the dark accent treated the same way.
    ///
    /// How much saturation comes out is `ContrastPolicy`'s call: at increased contrast the frame is
    /// the *only* thing marking the focused pane, because the dimming of the others is gone.
    private static func activePaneBorder(_ contrast: ColorSchemeContrast) -> Color {
        let factor = ContrastPolicy.paneBorderSaturation(contrast)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = NSColor.controlAccentColor
            appearance.performAsCurrentDrawingAppearance {
                guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
                resolved = NSColor(
                    hue: accent.hueComponent,
                    saturation: accent.saturationComponent * factor,
                    brightness: accent.brightnessComponent * 0.91,
                    alpha: 1
                )
            }
            return resolved
        })
    }

    private func pane(_ paneId: String, cols: Int, rows: Int) -> some View {
        let focused = focusedPaneId == paneId
            || (focusedPaneId == nil && paneId == window.preferredPaneId)
        // A single pane is not ambiguous, so it is neither framed nor dimmed.
        let split = window.paneCount > 1
        return TerminalPaneView(
            hostId: hostId,
            paneId: paneId,
            cols: cols,
            rows: rows,
            isFocused: focused,
            theme: theme,
            allowsRemoteClipboardWrite: allowsRemoteClipboardWrite,
            service: service,
            onFocusRequest: { focus(paneId) }
        )
        // Inactive panes step back so the focused one is findable without reading any of them. Kept
        // mild rather than dramatic: the other panes are usually still worth watching, which is the
        // whole reason the window is split. Not at all, at increased contrast — see `ContrastPolicy`.
        .opacity(
            split && !focused
                ? ContrastPolicy.inactivePaneOpacity(contrast, standard: Self.inactivePaneOpacity)
                : 1
        )
        .overlay {
            // A frame on all four sides, not an edge between two panes.
            //
            // The two-point edge this replaced was drawn along the top of the focused pane, which put
            // it exactly where the divider above it already was — so it read as a divider that had
            // turned blue, and which of the two panes it belonged to was a guess. Enclosing the pane
            // names it. Inset by a point so the stroke never lands on the seam itself, and the
            // dividers stay neutral so nothing competes with it.
            //
            // One point of desaturated accent, not one and a half of the full one. The saturated frame
            // was permanent and competed with the pane's own text for attention — and it is not the
            // real focus indicator anyway. The block cursor is, and it should stay the loudest thing on
            // screen.
            if split && focused {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        Self.activePaneBorder(contrast),
                        lineWidth: ContrastPolicy.paneBorderWidth(contrast)
                    )
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { modeBadge(paneId) }
        .contentShape(Rectangle())
        .onTapGesture { focus(paneId) }
        // Explicit identity. Without it the type-erased tree rebuilds every surface on each state
        // broadcast, discarding the terminal's contents each time.
        .id(paneId)
    }

    /// Says, on the pane itself, that tmux is showing an overlay here.
    ///
    /// The status bar names the *focused* pane's mode and that is not enough on its own: a split
    /// window can have one pane in copy mode while another has focus, and the frozen one is the one
    /// the user is puzzled by. Control mode is never streamed a mode's screen, so the pane is holding
    /// a `capture-pane` still frame — it looks exactly like a pane whose process has died, which is
    /// the wrong conclusion to leave anybody with.
    ///
    /// Worded, not a dot: the word is what tells someone they can press `q`.
    @ViewBuilder
    private func modeBadge(_ paneId: String) -> some View {
        if let pane = window.panes.first(where: { $0.id == paneId }), pane.isInMode {
            Text(pane.mode)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .padding(4)
                .allowsHitTesting(false)
                .help("This pane is in tmux's \(pane.mode). Keys go to the mode, not the shell.")
                .accessibilityLabel("Pane \(paneId) is in \(pane.mode)")
        }
    }

    private func focus(_ paneId: String) {
        guard focusedPaneId != paneId else { return }
        focusedPaneId = paneId
        Task { await service.selectPane(hostId: hostId, paneId: paneId) }
    }

    private func updateContainerSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != containerSize else { return }
        containerSize = size
        requestSizes()
    }

    /// §3.3 step 2: measure, then ask. tmux answers with `%layout-change`, and we lay out from that.
    ///
    /// Two requests, because they answer different questions: `resize-window` sizes *this* tmux window,
    /// which is what makes a torn-off macOS window independent, and `refresh-client -C` sizes the
    /// client, which is all a tmux older than 2.9 understands.
    ///
    /// R3.7's other half is the gate: during a live resize the ask is held instead of sent, and the
    /// drag ends with one request at the size the user let go of. The size is computed *now* and
    /// captured, so what is held is a finished question rather than a promise to measure later.
    private func requestSizes() {
        let cell = theme.cellSize(backingScaleFactor: backingScaleFactor)
        guard cell.width > 0, cell.height > 0 else { return }
        guard containerSize.width > 1, containerSize.height > 1 else { return }
        let cols = Int(containerSize.width / cell.width)
        let rows = Int(containerSize.height / cell.height)
        guard cols > 1, rows > 1 else { return }

        let (hostId, windowId, owner, drivesClientSize) =
            (self.hostId, window.id, self.owner, self.drivesClientSize)
        let service = self.service
        liveResize.submit(key: windowId) {
            Task {
                await service.requestWindowSize(
                    hostId: hostId, windowId: windowId, cols: cols, rows: rows, owner: owner
                )
                if drivesClientSize {
                    await service.requestClientSize(hostId: hostId, cols: cols, rows: rows)
                }
            }
        }
    }
}

/// The draggable boundary between two panes.
///
/// An `NSView` rather than a SwiftUI gesture, and not by preference. A pane surface is SwiftTerm's
/// `TerminalView`, a real `NSView` that tracks the mouse for text selection; a `DragGesture` layered
/// over it in a `ZStack` never sees a single event, whatever the z-order says. Hit-testing at the
/// AppKit level is the only thing the terminal cannot out-argue — which also gets a proper resize
/// cursor for free, via `resetCursorRects`.
///
/// Reports a target *cell* count rather than points, and only when that count changes, so dragging
/// across a pane costs one command per column crossed rather than one per frame. tmux remains the
/// authority: this asks, and the panes move when `%layout-change` says so (§3.3).
struct PaneDivider: NSViewRepresentable {
    let isRow: Bool
    /// The leading child's current extent in cells, which the drag is measured from.
    let baseCells: Int
    /// Points per cell along the axis being dragged.
    let cellExtent: CGFloat
    let onResize: (Int) -> Void

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.configure(isRow: isRow, baseCells: baseCells, cellExtent: cellExtent, onResize: onResize)
        return view
    }

    func updateNSView(_ view: DividerView, context: Context) {
        // Not while a drag is in flight: the layout is changing underneath as tmux answers, and
        // adopting the new base mid-gesture would measure each frame from a moved starting point —
        // the pane would accelerate away from the pointer.
        view.configure(isRow: isRow, baseCells: baseCells, cellExtent: cellExtent, onResize: onResize)
    }

    final class DividerView: NSView {
        private var isRow = true
        private var baseCells = 1
        private var cellExtent: CGFloat = 1
        private var onResize: ((Int) -> Void)?

        /// Captured at mouse-down and held for the whole drag, for the reason above.
        private var dragStartCells: Int?
        private var dragOrigin: NSPoint?
        private var lastSent: Int?

        func configure(isRow: Bool, baseCells: Int, cellExtent: CGFloat, onResize: @escaping (Int) -> Void) {
            self.isRow = isRow
            self.cellExtent = cellExtent
            self.onResize = onResize
            // A live drag owns the baseline; anything else is free to update it.
            if dragStartCells == nil { self.baseCells = baseCells }
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isRow ? .resizeLeftRight : .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            dragStartCells = baseCells
            dragOrigin = event.locationInWindow
            lastSent = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStartCells, let origin = dragOrigin, cellExtent > 0 else { return }
            let point = event.locationInWindow
            // AppKit's y grows upward and tmux's rows grow downward, so a downward drag has to read as
            // *more* rows for the pane above the boundary.
            let moved = isRow ? (point.x - origin.x) : (origin.y - point.y)
            let target = max(1, start + Int((moved / cellExtent).rounded()))
            guard target != lastSent else { return }
            lastSent = target
            onResize?(target)
        }

        override func mouseUp(with event: NSEvent) {
            dragStartCells = nil
            dragOrigin = nil
            lastSent = nil
        }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only the handle itself; never swallow clicks meant for a pane beside it.
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}
