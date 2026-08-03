import Foundation

public struct StoredHost: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var isLocal: Bool
    public var customCommand: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        isLocal: Bool = false,
        customCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.isLocal = isLocal
        self.customCommand = customCommand
    }

    public var asConfig: HostConfig {
        HostConfig(
            id: id, name: name, hostname: hostname, user: user,
            port: port, isLocal: isLocal, customCommand: customCommand
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
