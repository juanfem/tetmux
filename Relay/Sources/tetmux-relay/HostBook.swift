import Foundation
import tetmuxCore

/// Hosts added, edited and removed from the browser: checked, saved to `hosts.json`, and handed to
/// the service.
///
/// Saved through `HostConfigStore` so a host added from the phone is the same record the Mac app
/// would have written, with the same id scheme — and survives a relay restart.
actor HostBook {
    private let store: HostConfigStore
    private let service: SessionService

    /// The hosts the page may edit or remove, for the topology to say so. A host given on the command
    /// line with `--host` and found nowhere is offered but not in the file, so it is not among them.
    private(set) var editableIds: Set<String>

    init(store: HostConfigStore, service: SessionService, saved: [StoredHost]) {
        self.store = store
        self.service = service
        self.editableIds = Set(saved.filter { Self.isEditable(id: $0.id, isLocal: $0.isLocal) }.map(\.id))
    }

    enum Refusal: Error, CustomStringConvertible {
        case invalid(String)
        case exists(String)
        case unsaved(String)
        case notEditable(String)

        var description: String {
            switch self {
            case .invalid(let why): return why
            case .exists(let name): return "\(name) is already in the list"
            case .unsaved(let why): return "could not save hosts.json: \(why)"
            case .notEditable(let name): return "\(name) is not a host saved in hosts.json, so it cannot be changed here"
            }
        }
    }

    /// Adds `user@host` (or `host`), returning the new host's id.
    func add(destination: String, port: Int?, name: String?) async throws -> String {
        let (user, hostname) = try Self.parse(destination)
        if let port, !(1...65535).contains(port) {
            throw Refusal.invalid("port \(port) is out of range")
        }
        let label = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? hostname

        // Fresh from disk rather than the list the relay started with: that one has the local host
        // renamed after the machine, and saving it would write the rename into the file.
        var hosts = await store.loadHosts()
        let id = "custom-\(label)"
        guard !hosts.contains(where: { $0.id == id || $0.name == label }) else {
            throw Refusal.exists(label)
        }
        let host = StoredHost(id: id, name: label, hostname: hostname, user: user, port: port)
        hosts.append(host)
        do {
            try await store.saveHosts(hosts)
        } catch {
            throw Refusal.unsaved(error.localizedDescription)
        }
        editableIds.insert(id)
        await service.addHost(host.asConfig)
        return id
    }

    /// Which hosts the page may edit or remove: the remote ones `hosts.json` owns. The local host
    /// always exists, and a host from `~/.ssh/config` exists because its stanza does — changing either
    /// here would be overridden, or undone, by the place it really comes from.
    static func isEditable(id: String, isLocal: Bool) -> Bool {
        !isLocal && !id.hasPrefix("ssh-")
    }

    /// Changes a saved host's destination, port and name. Everything else about it — forwards, ssh
    /// options, colour, what the Mac app set — is kept as it is. The id does not change, so what is
    /// keyed on it (the page's view, the workspace) still finds the host.
    ///
    /// Whether ssh has to be run again: true when the change reaches the ssh command line, in which
    /// case the old channel, which goes somewhere else, has been dropped.
    func edit(id: String, destination: String, port: Int?, name: String?) async throws -> Bool {
        let (user, hostname) = try Self.parse(destination)
        if let port, !(1...65535).contains(port) {
            throw Refusal.invalid("port \(port) is out of range")
        }
        var hosts = await store.loadHosts()
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              Self.isEditable(id: id, isLocal: hosts[index].isLocal) else {
            throw Refusal.notEditable(await service.getHost(id)?.config.name ?? id)
        }
        let label = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? hostname
        guard !hosts.contains(where: { $0.id != id && $0.name == label }) else {
            throw Refusal.exists(label)
        }

        let before = hosts[index]
        hosts[index].name = label
        hosts[index].hostname = hostname
        hosts[index].user = user
        hosts[index].port = port
        do {
            try await store.saveHosts(hosts)
        } catch {
            throw Refusal.unsaved(error.localizedDescription)
        }
        let moved = (before.hostname ?? before.name) != hostname || before.user != user || before.port != port
        if moved {
            // Dropped before the new config goes in, so nothing reconnects the old destination's
            // channel under the new name. The page's next look at the host connects the new one.
            await service.disconnectHost(hostId: id)
        }
        await service.addHost(hosts[index].asConfig)
        return moved
    }

    /// Takes a saved host out of `hosts.json` and off the relay. Its tmux sessions are untouched:
    /// this drops the relay's channel to them, as quitting the Mac app would.
    func remove(id: String) async throws {
        var hosts = await store.loadHosts()
        guard let host = hosts.first(where: { $0.id == id }),
              Self.isEditable(id: id, isLocal: host.isLocal) else {
            throw Refusal.notEditable(await service.getHost(id)?.config.name ?? id)
        }
        hosts.removeAll { $0.id == id }
        do {
            try await store.saveHosts(hosts)
        } catch {
            throw Refusal.unsaved(error.localizedDescription)
        }
        editableIds.remove(id)
        await service.removeHost(hostId: id)
    }

    /// `user@host` → (`user`, `host`).
    ///
    /// Strict, because both halves end up as arguments to `ssh`: a destination beginning with `-` is
    /// an option to ssh (`-oProxyCommand=…` runs a command), and whitespace or a control character
    /// would split or end the argument somewhere along the way. Hostnames, IPv4 and IPv6 addresses
    /// and ssh-config aliases all fit in what is left.
    static func parse(_ destination: String) throws -> (user: String?, host: String) {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { throw Refusal.invalid("more than one @ in \(trimmed)") }
        let user = parts.count == 2 ? parts[0] : nil
        let host = parts.count == 2 ? parts[1] : parts[0]

        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:[]"))
        let userCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !host.isEmpty, !host.hasPrefix("-"), Self.only(hostCharacters, in: host) else {
            throw Refusal.invalid("not a host name: \(host.isEmpty ? "(empty)" : host)")
        }
        if let user {
            guard !user.isEmpty, !user.hasPrefix("-"), Self.only(userCharacters, in: user) else {
                throw Refusal.invalid("not a user name: \(user.isEmpty ? "(empty)" : user)")
            }
        }
        return (user, host)
    }

    private static func only(_ allowed: CharacterSet, in string: String) -> Bool {
        // ASCII only: `alphanumerics` admits every script's letters, and a hostname that looks like
        // `examp1e.com` in another alphabet is not one this should accept from a text field.
        string.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}
