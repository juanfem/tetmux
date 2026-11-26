import tetmuxCore

/// F4.38 — which colour each remote host is shown in.
///
/// A decision over the whole host list rather than per host, because "automatic" has to mean
/// "distinct": with eight colours, hashing each host on its own gives two of three hosts the same
/// colour about a third of the time, and two hosts that look alike defeat the point of colouring
/// them. So hosts with a colour chosen for them claim it first, and each automatic host then takes
/// the colour its id hashes to — or, if that is taken, the next free one round the palette.
///
/// The automatic hosts are visited in id order, not list order. The list's order is not stable —
/// saving a host moves it to the end of `hosts.json` — and a host's colour changing because it was
/// edited would make the colour useless as a memory aid. What remains is that adding a host can move
/// the colour of one that was sharing its first choice; choosing a colour pins it.
public enum HostColorPolicy {
    /// The colours handed out without being asked for. Red is not among them: it is what someone
    /// picks to mean "careful, production", and that only works if red is never an accident.
    public static let automaticPalette: [HostColor] = [
        .blue, .teal, .green, .ochre, .orange, .purple, .pink, .graphite,
    ]

    /// The colour each coloured host is shown in, by host id. The local host and any host set to
    /// `.none` are absent: no colour is the answer, not a missing one.
    public static func resolve(_ hosts: [HostConfig]) -> [String: HostColor] {
        var result: [String: HostColor] = [:]
        var taken = Set<HostColor>()

        for host in hosts where !host.isLocal {
            if case .fixed(let color) = host.color {
                result[host.id] = color
                taken.insert(color)
            }
        }

        let automatic = hosts
            .filter { !$0.isLocal && $0.color == .automatic && result[$0.id] == nil }
            .sorted { $0.id < $1.id }
        let count = automaticPalette.count
        for host in automatic {
            let start = preferredIndex(for: host.id)
            let free = (0..<count)
                .map { automaticPalette[(start + $0) % count] }
                .first { !taken.contains($0) }
            // More hosts than colours: sharing is unavoidable, so share the stable first choice.
            let color = free ?? automaticPalette[start]
            result[host.id] = color
            taken.insert(color)
        }
        return result
    }

    /// FNV-1a over the id's UTF-8. Not `Hasher`, which is seeded per process: a host would change
    /// colour on every launch.
    static func preferredIndex(for id: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(automaticPalette.count))
    }
}
