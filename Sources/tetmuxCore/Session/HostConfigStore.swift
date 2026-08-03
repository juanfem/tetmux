import Foundation

public struct StoredHost: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var isLocal: Bool
    public var customCommand: String?
    public var usesPassword: Bool
    /// Whether the password is expected in the Keychain. **No password is ever written here** —
    /// `hosts.json` is plain text the user is invited to read, and §2.5 keeps credentials out of it
    /// entirely.
    public var storesPasswordInKeychain: Bool
    public var forwards: [PortForward]

    public init(
        id: String = UUID().uuidString,
        name: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        isLocal: Bool = false,
        customCommand: String? = nil,
        usesPassword: Bool = false,
        storesPasswordInKeychain: Bool = false,
        forwards: [PortForward] = []
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.isLocal = isLocal
        self.customCommand = customCommand
        self.usesPassword = usesPassword
        self.storesPasswordInKeychain = storesPasswordInKeychain
        self.forwards = forwards
    }

    /// Decoded field by field rather than by the synthesised initialiser, so a `hosts.json` written
    /// before these fields existed still loads. The synthesised version treats a missing
    /// non-optional key as a decoding failure, and one such failure discards the *entire* host list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        customCommand = try container.decodeIfPresent(String.self, forKey: .customCommand)
        usesPassword = try container.decodeIfPresent(Bool.self, forKey: .usesPassword) ?? false
        storesPasswordInKeychain =
            try container.decodeIfPresent(Bool.self, forKey: .storesPasswordInKeychain) ?? false
        forwards = try container.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
    }

    public var asConfig: HostConfig {
        HostConfig(
            id: id, name: name, hostname: hostname, user: user,
            port: port, isLocal: isLocal, customCommand: customCommand,
            usesPassword: usesPassword, storesPasswordInKeychain: storesPasswordInKeychain,
            forwards: forwards
        )
    }
}

extension HostConfig {
    /// The persistable form of a config, so a host can be round-tripped through an editor without the
    /// UI having to hold both representations of it.
    public var asStoredHost: StoredHost {
        StoredHost(
            id: id, name: name, hostname: hostname, user: user, port: port,
            isLocal: isLocal, customCommand: customCommand,
            usesPassword: usesPassword, storesPasswordInKeychain: storesPasswordInKeychain,
            forwards: forwards
        )
    }
}

/// `hosts.json` in Application Support (§2.3). Plain JSON on purpose: the stored data is a host
/// list, and human-readability is worth more here than a database.
public actor HostConfigStore {
    private let storeURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tetmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("hosts.json")
    }

    /// The local host, then anything the user saved, then a conservative scan of `~/.ssh/config`
    /// (F4.2). Saved entries win over discovered ones with the same name.
    public func loadHosts() -> [StoredHost] {
        var hosts: [StoredHost] = [StoredHost(id: "local", name: "localhost", isLocal: true)]

        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([StoredHost].self, from: data) {
            for host in saved where !hosts.contains(where: { $0.id == host.id }) {
                hosts.append(host)
            }
        }

        for discovered in discoverSSHHosts() where !hosts.contains(where: { $0.name == discovered.name }) {
            hosts.append(discovered)
        }

        return hosts
    }

    public func saveHosts(_ hosts: [StoredHost]) throws {
        // "local" is implicit and discovered hosts are re-derived on each launch; persisting either
        // would leave stale entries behind when ~/.ssh/config changes.
        let persisted = hosts.filter { $0.id != "local" && !$0.id.hasPrefix("ssh-") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persisted).write(to: storeURL, options: .atomic)
    }

    /// Host *names* only, from `Host` stanzas without wildcards. Resolution of what those names
    /// mean is left to `ssh -G`; `~/.ssh/config` is not a format worth reimplementing (§2.3).
    private func discoverSSHHosts() -> [StoredHost] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }

        var results: [StoredHost] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyword = fields.first, keyword.lowercased() == "host" else { continue }

            for pattern in fields.dropFirst() {
                let name = String(pattern)
                guard !name.contains("*"), !name.contains("?"), !name.hasPrefix("!"),
                      name != "localhost",
                      !results.contains(where: { $0.name == name }) else { continue }
                results.append(StoredHost(id: "ssh-\(name)", name: name, isLocal: false))
            }
        }
        return results
    }

    /// F4.2 — `ssh -G` yields the fully resolved effective configuration for a host, including
    /// everything `Include`, `Match`, and canonicalisation contributed.
    public static func resolveEffectiveConfig(for hostName: String) async -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", hostName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }
        var config: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            config[String(parts[0]).lowercased()] = String(parts[1])
        }
        return config
    }
}
