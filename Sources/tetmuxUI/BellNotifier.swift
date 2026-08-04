import AppKit
import UserNotifications

/// F4.31 — turns a pane's bell into a Notification Center alert when tetmux is in the background.
///
/// Deliberately small and best-effort. Notification authorisation is a user decision that can be
/// declined or revoked at any time, and a terminal that cannot ring is a far smaller problem than one
/// that nags for permission, so nothing here surfaces an error and nothing retries a refusal.
///
/// Coalesced, because a bell is not rate-limited by anything: a `yes` piped into something that rings,
/// or a shell in a loop, produces hundreds per second, and one banner each would bury the Notification
/// Center and every other application's alerts with it.
@MainActor
final class BellNotifier {
    static let shared = BellNotifier()

    /// How long after a bell further bells are folded into the same notification.
    private static let coalescingWindow: Duration = .seconds(10)

    private var authorization: Authorization = .unknown
    private var lastPostedAt: ContinuousClock.Instant?
    private var suppressedSinceLastPost = 0

    private enum Authorization {
        case unknown, requesting, granted, denied
    }

    private init() {}

    /// `UNUserNotificationCenter.current()` raises rather than returning nil in a process with no
    /// bundle identifier, and `swift run tetmux` is exactly that — a bare Mach-O with no `.app`
    /// around it, which is the documented way to run this during development. Crashing the app on a
    /// bell would be a memorable way to find that out.
    private var notificationsAreAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func post(paneId: String) {
        guard notificationsAreAvailable else { return }
        switch authorization {
        case .denied, .requesting:
            return
        case .unknown:
            requestAuthorization(thenPostFor: paneId)
            return
        case .granted:
            break
        }

        if let last = lastPostedAt, last.duration(to: .now) < Self.coalescingWindow {
            suppressedSinceLastPost += 1
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Bell in \(paneId)"
        content.body = suppressedSinceLastPost > 0
            ? "and \(suppressedSinceLastPost) more since the last alert"
            : "A pane rang while tetmux was in the background."
        content.sound = nil  // `NSSound.beep()` has already happened; two sounds is one too many.

        lastPostedAt = .now
        suppressedSinceLastPost = 0
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// Asks once, on the first bell rather than at launch: permission is far more explicable when
    /// something has just happened that would have used it.
    private func requestAuthorization(thenPostFor paneId: String) {
        authorization = .requesting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = granted ? .granted : .denied
                // The bell that prompted the request still deserves its alert, if the user said yes.
                if granted { self.post(paneId: paneId) }
            }
        }
    }
}
