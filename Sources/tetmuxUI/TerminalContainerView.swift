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

    /// Divider thickness between splits, in points.
    private let dividerWidth: CGFloat = 1

    @State private var cellSize: CGSize?
    @State private var containerSize: CGSize = .zero

    public init(
        hostId: String,
        window: TmuxWindow,
        theme: TerminalTheme = .default,
        service: SessionService,
        focusedPaneId: Binding<String?>
    ) {
        self.hostId = hostId
        self.window = window
        self.theme = theme
        self.service = service
        self._focusedPaneId = focusedPaneId
    }

    public var body: some View {
        GeometryReader { proxy in
            content(in: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onAppear { updateContainerSize(proxy.size) }
                .onChange(of: proxy.size) { _, newValue in updateContainerSize(newValue) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if let tree = window.layoutTree {
            node(tree, size: size)
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

    private func pane(_ paneId: String, cols: Int, rows: Int) -> some View {
        let focused = focusedPaneId == paneId
            || (focusedPaneId == nil && paneId == window.preferredPaneId)
        return TerminalPaneView(
            hostId: hostId,
            paneId: paneId,
            cols: cols,
            rows: rows,
            isFocused: focused,
            theme: theme,
            service: service,
            onMetrics: { metrics in
                guard let cell = metrics.cellSize, cell != cellSize else { return }
                cellSize = cell
                requestClientSize()
            },
            onFocusRequest: { focus(paneId) }
        )
        .overlay(alignment: .top) {
            // A two-point edge is enough to say which pane has the keyboard, without chrome that
            // would eat a row of cells.
            if focused && window.paneCount > 1 {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focus(paneId) }
        // Explicit identity. Without it the type-erased tree rebuilds every surface on each state
        // broadcast, discarding the terminal's contents each time.
        .id(paneId)
    }

    private func focus(_ paneId: String) {
        guard focusedPaneId != paneId else { return }
        focusedPaneId = paneId
        Task { await service.selectPane(hostId: hostId, paneId: paneId) }
    }

    private func updateContainerSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != containerSize else { return }
        containerSize = size
        requestClientSize()
    }

    /// §3.3 step 2: measure, then ask. tmux answers with `%layout-change`, and we lay out from that.
    private func requestClientSize() {
        guard let cell = cellSize, cell.width > 0, cell.height > 0 else { return }
        guard containerSize.width > 1, containerSize.height > 1 else { return }
        let cols = Int(containerSize.width / cell.width)
        let rows = Int(containerSize.height / cell.height)
        guard cols > 1, rows > 1 else { return }
        Task { await service.requestClientSize(hostId: hostId, cols: cols, rows: rows) }
    }
}
