import AppKit
import Foundation
import Network

/// F4.18 — sleep/wake and network changes drive reconnection directly rather than being noticed by
/// a timeout. Closing the lid on a train and reopening it at the office should restore every
/// session without user action.
public final class NetworkStateMonitor: @unchecked Sendable {
    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tetmux.network.monitor")
    private let onChange: @Sendable () -> Void
    private var wasSatisfied = true
    private var wakeObserver: NSObjectProtocol?

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChange()
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let previous = self.wasSatisfied
            self.wasSatisfied = satisfied
            // Only the transition back to reachable is interesting; the drop itself already shows
            // up as a dead channel.
            guard satisfied, !previous else { return }
            self.onChange()
        }
        pathMonitor.start(queue: queue)
    }

    deinit {
        pathMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
