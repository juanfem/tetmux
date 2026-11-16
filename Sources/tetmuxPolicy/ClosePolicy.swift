import tetmuxCore

/// What closing a window will actually do (F4.9).
///
/// The difference is invisible and irreversible in one direction: linked into several sessions,
/// closing is `unlink-window` and nothing dies; linked into one, closing *is* killing. The macOS
/// confirmation explains that at the moment of the click, but ⌥ skips the confirmation — so without
/// something saying it beforehand, "this tab goes away" and "this build dies" are the same gesture.
/// One decision, every reader — the tooltip, the close itself, and any other front end — so nothing
/// can promise what the action will not do.
public enum CloseOutcome: Equatable, Sendable {
    /// The window leaves this session and carries on in the ones named.
    case unlinks(remaining: [String])
    /// This session is its only one, so removing it there is destroying it.
    case kills
}

/// F4.9/F4.10's decisions, over a topology snapshot and nothing else.
///
/// Lives below the UI so that every front end — the macOS app, the relay's browser client — asks the
/// same question the same way. It needs no channel: the answer is a filter over what
/// `list-windows -a` already reported.
public enum ClosePolicy {
    /// The host's sessions this window is linked into, in tree order.
    ///
    /// `list-windows -a` reports a linked window once per session, so the model already carries it in
    /// each one and this is a filter rather than a query.
    public static func linkedSessions(in hosts: [HostState], hostId: String, windowId: String) -> [TmuxSession] {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return [] }
        return host.sessions.filter { session in session.windows.contains { $0.id == windowId } }
    }

    /// An unknown host or window is `.kills`: that is the case that asks, and treating "linked into
    /// nothing" as a safe unlink would let a close skip the confirmation it owes.
    public static func outcome(
        in hosts: [HostState], hostId: String, windowId: String, closingIn sessionId: String? = nil
    ) -> CloseOutcome {
        let linked = linkedSessions(in: hosts, hostId: hostId, windowId: windowId)
        guard linked.count > 1 else { return .kills }
        return .unlinks(remaining: linked.filter { $0.id != sessionId }.map(\.name))
    }

    /// The sentence a close control puts in its tooltip, and what a screen reader is told.
    ///
    /// Names the sessions rather than counting them: "it stays in build and deploy" is checkable and
    /// "linked into 3 sessions" is a number the user then has to go and resolve. Truncated past three,
    /// because a tooltip is not a list.
    public static func description(of outcome: CloseOutcome, windowName: String) -> String {
        switch outcome {
        case .kills:
            return "Close \(windowName) — this is its only session, so it ends what is running in it"
        case .unlinks(let remaining):
            let named = remaining.prefix(3).joined(separator: ", ")
            let rest = remaining.count > 3 ? " and \(remaining.count - 3) more" : ""
            return "Remove \(windowName) from this session — it keeps running in \(named)\(rest)"
        }
    }
}
