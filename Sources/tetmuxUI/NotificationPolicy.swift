import Foundation

/// F4.31 — which events are worth a Notification Center banner, and for what.
///
/// The bell half was hard-coded: a pane rang, the app was not frontmost, a banner went out. That is
/// the right default and the wrong contract — a terminal that rings is not the only thing worth being
/// told about, and it is not something everyone wants to be told about at all.
///
/// Two events, because they answer different questions. A **bell** is a program deliberately asking
/// for attention. **Activity** is output arriving in a window nobody is looking at, which is what a
/// long remote job that prints and does not ring looks like — and it is far too noisy to report for
/// every window, so it is reported only for windows the user has explicitly *watched*. That is the
/// whole reason activity is opt-in per window while the bell is not: the bell has a sender, activity
/// has only a stream.
///
/// `UserDefaults`, beside `TerminalTheme` and for the same reason: these are ordinary application
/// preferences, and §2.3's argument for a JSON file is about documents somebody may want to read,
/// diff, or copy to another Mac. The *watches* themselves are view state and live in `workspace.json`.
public struct NotificationPolicy: Equatable, Sendable {
    /// Post a banner when a pane rings while tetmux is in the background.
    public var bells: Bool
    /// Post a banner when a **watched** window goes from quiet to active while tetmux is in the
    /// background. Does nothing on its own: with no watched windows there is nothing to report.
    public var activity: Bool

    public static let `default` = NotificationPolicy(bells: true, activity: true)

    public init(bells: Bool, activity: Bool) {
        self.bells = bells
        self.activity = activity
    }

    private enum Key {
        static let bells = "notifications.bells"
        static let activity = "notifications.activity"
    }

    public static func load(from defaults: UserDefaults = .standard) -> NotificationPolicy {
        var policy = NotificationPolicy.default
        // `bool(forKey:)` answers false for a key that was never written, which is not the default —
        // so the presence of the key is what decides, exactly as `TerminalTheme` does for ligatures.
        if defaults.object(forKey: Key.bells) != nil {
            policy.bells = defaults.bool(forKey: Key.bells)
        }
        if defaults.object(forKey: Key.activity) != nil {
            policy.activity = defaults.bool(forKey: Key.activity)
        }
        return policy
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(bells, forKey: Key.bells)
        defaults.set(activity, forKey: Key.activity)
    }
}

/// One tmux window somebody asked to be told about, qualified by its host.
///
/// Host-qualified because tmux numbers windows per *server*: `@1` exists on every host at once, and
/// that is the ordinary case rather than a corner one, since the usual way to reach a second host is
/// to ssh into it and its tmux starts counting from zero exactly like the first.
public struct WatchedWindow: Codable, Equatable, Hashable, Sendable {
    public var hostId: String
    /// `@id`
    public var windowId: String

    public init(hostId: String, windowId: String) {
        self.hostId = hostId
        self.windowId = windowId
    }
}
