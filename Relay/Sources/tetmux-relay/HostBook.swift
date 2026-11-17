import Foundation
import tetmuxCore

/// Hosts added from the browser: checked, saved to `hosts.json`, and handed to the service.
///
/// Saved through `HostConfigStore` so a host added from the phone is the same record the Mac app
/// would have written, with the same id scheme — and survives a relay restart.
actor HostBook {
    private let store: HostConfigStore
    private let service: SessionService

    init(store: HostConfigStore, service: SessionService) {
        self.store = store
        self.service = service
    }

    enum Refusal: Error, CustomStringConvertible {
        case invalid(String)
        case exists(String)
        case unsaved(String)

        var description: String {
            switch self {
            case .invalid(let why): return why
            case .exists(let name): return "\(name) is already in the list"
            case .unsaved(let why): return "could not save hosts.json: \(why)"
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
        await service.addHost(host.asConfig)
        return id
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
