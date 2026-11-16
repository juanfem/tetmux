import tetmuxCore

/// Arithmetic over a window's tabs and panes that every front end needs and none should re-derive.
public enum TabOrder {
    /// Where a dragged tab lands, in the form `move-window`'s "insert before" wants.
    ///
    /// The rule every tab bar has: the dragged tab takes the target's position and the tabs between
    /// them shift by one. Which side of the target that is depends on the direction of travel, and
    /// getting it wrong makes a rightward drag by one position do nothing at all, which reads as the
    /// whole feature being broken.
    ///
    /// Returns the window to insert in front of, `nil` for the end of the strip, and `.none` for a
    /// drop that is not a move. Pure because the arithmetic is the whole of it: the tmux side is one
    /// command, and this is the part that can be wrong without anything saying so.
    public static func dropDestination(order: [String], dragged: String, onto target: String) -> String?? {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let onto = order.firstIndex(of: target) else { return .none }

        var remaining = order
        remaining.remove(at: from)
        guard let targetIndex = remaining.firstIndex(of: target) else { return .none }
        // Rightwards: land after the target, which is the window currently following it — or the end
        // of the strip when the target is last. Leftwards: land on the target itself.
        let insertAt = from < onto ? targetIndex + 1 : targetIndex
        return .some(insertAt < remaining.count ? remaining[insertAt] : nil)
    }

    /// Both records of what a window holds, together.
    ///
    /// The layout tree is updated by `%layout-change` and `panes` by the `list-panes` that follows it,
    /// so at the instant a split lands one of them has already grown and the other has not. A pane in
    /// either is a pane that was already there.
    public static func paneIds(of window: TmuxWindow) -> Set<String> {
        Set(window.panes.map(\.id)).union(window.layoutTree?.paneIds ?? [])
    }
}
