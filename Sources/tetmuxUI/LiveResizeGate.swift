import AppKit

/// R3.7's other half: while a macOS window is being dragged by an edge, its panes ask tmux nothing.
///
/// §3.3 asks for two things and only the debounce was built. Requests are coalesced at 100 ms, so a
/// drag is a `refresh-client -C` every tenth of a second, each answered with a `%layout-change`, each
/// relaying out every pane on screen. Nothing corrupts — tmux stays authoritative and the last answer
/// wins — which is exactly why it went unnoticed: it presents as a heavy drag and a churning layout
/// that nobody attributes to the protocol underneath.
///
/// So a request made during a live resize is *held* rather than sent, and the drag ends with exactly
/// one request at the size the user actually let go of.
///
/// Two things about it are load-bearing.
///
/// **The held request is keyed**, because every tmux window of the session is built and measuring
/// itself — the unselected ones are hidden with `.opacity(0)`, not omitted, and they have real frames.
/// A single held closure would let the last tab laid out overwrite the rest, and every other tab would
/// come out of the drag still holding the grid it had before it, silently, until something unrelated
/// resized it. One slot per tmux window; last size within the drag wins, which is the final size.
///
/// **The gate is per macOS window**, because another window's panes are not the ones being dragged.
/// It observes one `NSWindow` and nothing else.
@MainActor
public final class LiveResizeGate {
    /// Whether the observed window is between `willStartLiveResize` and `didEndLiveResize`.
    public private(set) var isLiveResizing = false

    /// The most recent held request per key. Replaced rather than appended: within one drag only the
    /// last size asked for is worth sending, and the sizes before it are the churn this exists to stop.
    private var held: [String: () -> Void] = [:]
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    // No `deinit` unregistration, and it is not an oversight: a `deinit` is nonisolated and cannot
    // touch this actor-isolated state at all. The window that closes is what says so, from
    // `onDisappear` — which is also the only reliable signal, since `nsWindow` is weak and a
    // reference nilled by ARC does not run `didSet`.

    /// Follows one window's live-resize notifications. Replaces any previous subscription, since a
    /// `WindowState` is handed its `NSWindow` by `WindowAccessor` and may be handed another.
    ///
    /// `queue: nil` deliberately: with an `OperationQueue` the block is *enqueued* rather than run, so
    /// the start of a drag would arrive after SwiftUI had already reported the first few sizes — which
    /// is the ordering this depends on. Delivered synchronously on the posting thread, which for an
    /// `NSWindow` notification is the main one.
    public func observe(_ window: NSWindow) {
        stopObserving()
        observers = [
            center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.begin() }
            },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
        ]
    }

    public func stopObserving() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Send now, or hold until the drag ends. `key` is what the caller would overwrite: a tmux window
    /// id, so each tab keeps its own final size.
    public func submit(key: String, _ request: @escaping () -> Void) {
        if isLiveResizing {
            held[key] = request
        } else {
            request()
        }
    }

    /// Nothing this gate is holding is worth sending any more — the view asking is going away.
    public func cancel(key: String) {
        held.removeValue(forKey: key)
    }

    func begin() {
        isLiveResizing = true
    }

    func end() {
        isLiveResizing = false
        let pending = held
        held = [:]
        for request in pending.values { request() }
    }
}
