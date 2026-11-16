import tetmuxCore

/// F4.31 — one watched window that went from quiet to active.
public struct ActivityAlert: Equatable, Sendable {
    public let hostId: String
    public let windowId: String
    /// `displayLabel`, which is the name if the user chose one and what is running otherwise —
    /// the same string the tab and the tree show, so the banner names the window they can see.
    public let label: String

    public init(hostId: String, windowId: String, label: String) {
        self.hostId = hostId
        self.windowId = windowId
        self.label = label
    }
}

public enum ActivityPolicy {
    /// Which watched windows went from quiet to active between two snapshots.
    ///
    /// Pure because it is the part that is silently wrong when it is wrong. `hasActivity` stays true
    /// until the window is looked at, so reporting on the *value* rather than on the *transition*
    /// would re-fire on every topology snapshot for as long as the window stays unread — a job that
    /// prints once would notify for the rest of the afternoon. A window that has only just appeared
    /// has no previous value, and is deliberately not reported: attaching to a server with a watched
    /// window already active is not the same event as it becoming active.
    public static func newlyActive(
        from previous: [HostState], to current: [HostState], watching watched: Set<WatchedWindow>
    ) -> [ActivityAlert] {
        guard !watched.isEmpty else { return [] }
        var wasActive: [WatchedWindow: Bool] = [:]
        for host in previous {
            for session in host.sessions {
                for window in session.windows {
                    // A window linked into several sessions appears more than once and is one window;
                    // active anywhere is active.
                    let key = WatchedWindow(hostId: host.id, windowId: window.id)
                    wasActive[key] = (wasActive[key] ?? false) || window.hasActivity
                }
            }
        }

        var alerts: [ActivityAlert] = []
        var reported: Set<WatchedWindow> = []
        for host in current {
            for session in host.sessions {
                for window in session.windows where window.hasActivity {
                    let key = WatchedWindow(hostId: host.id, windowId: window.id)
                    guard watched.contains(key), !reported.contains(key) else { continue }
                    guard let previouslyActive = wasActive[key], !previouslyActive else { continue }
                    reported.insert(key)
                    alerts.append(ActivityAlert(
                        hostId: host.id, windowId: window.id, label: window.displayLabel
                    ))
                }
            }
        }
        return alerts
    }
}
