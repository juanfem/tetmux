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
    private var wasSatisfied = false
    private var interfaces: Set<String> = []
    private var sawFirstUpdate = false
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
            let interfaces = Set(path.availableInterfaces.map(\.name))
            let previousSatisfied = self.wasSatisfied
            let previousInterfaces = self.interfaces
            let isFirst = !self.sawFirstUpdate
            self.wasSatisfied = satisfied
            self.interfaces = interfaces
            self.sawFirstUpdate = true

            // The first update just establishes a baseline — it fires at launch, when there is
            // nothing to reconnect.
            guard !isFirst, satisfied else { return }

            // Two different events mean the network moved under us. Coming back from unreachable is
            // the obvious one. The other is switching between two working networks — Wi-Fi to a
            // different Wi-Fi, or Wi-Fi to Ethernet — which never reports `.unsatisfied` at all, so
            // watching only the satisfied flag missed exactly the case where a host that had been
            // unreachable becomes reachable again.
            guard !previousSatisfied || interfaces != previousInterfaces else { return }
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
