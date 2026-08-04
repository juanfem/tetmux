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
    /// Extra `ssh` options as typed. Split into argv elements at connect time, never run by a shell.
    public var extraSshArguments: String
    public var forwardsX11: Bool

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
        forwards: [PortForward] = [],
        extraSshArguments: String = "",
        forwardsX11: Bool = false
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
        self.extraSshArguments = extraSshArguments
        self.forwardsX11 = forwardsX11
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
        extraSshArguments = try container.decodeIfPresent(String.self, forKey: .extraSshArguments) ?? ""
        forwardsX11 = try container.decodeIfPresent(Bool.self, forKey: .forwardsX11) ?? false
    }

    public var asConfig: HostConfig {
        HostConfig(
            id: id, name: name, hostname: hostname, user: user,
            port: port, isLocal: isLocal, customCommand: customCommand,
            usesPassword: usesPassword, storesPasswordInKeychain: storesPasswordInKeychain,
            forwards: forwards, extraSshArguments: extraSshArguments, forwardsX11: forwardsX11
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
            forwards: forwards, extraSshArguments: extraSshArguments, forwardsX11: forwardsX11
        )
    }
}

/// `hosts.json` in Application Support (§2.3). Plain JSON on purpose: the stored data is a host
/// list, and human-readability is worth more here than a database.
public actor HostConfigStore {
    private let storeURL: URL
    /// Injectable so the discovery and override rules can be tested against a known file rather than
    /// against whatever `~/.ssh/config` happens to hold on the machine running the tests.
    private let sshConfigURL: URL

    public init(directory: URL? = nil, sshConfigURL: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tetmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("hosts.json")
        self.sshConfigURL = sshConfigURL ?? FileManager.default
            .homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// Set when `hosts.json` was present but could not be read, in which case the file has been
    /// moved aside rather than left in the path of the next save. Cleared by a successful load.
    public private(set) var loadFailure: String?

    /// The local host, then anything the user saved, then a conservative scan of `~/.ssh/config`
    /// (F4.2). Saved entries win over discovered ones with the same name.
    public func loadHosts() -> [StoredHost] {
        var hosts: [StoredHost] = [StoredHost(id: "local", name: "localhost", isLocal: true)]
        let saved = loadSaved()

        // Built by hand rather than with `uniqueKeysWithValues`, which traps on a duplicate — and the
        // file is documented as something the user may open and edit.
        var savedById: [String: StoredHost] = [:]
        for host in saved where savedById[host.id] == nil { savedById[host.id] = host }

        for host in saved where !host.id.hasPrefix("ssh-") && !hosts.contains(where: { $0.id == host.id }) {
            hosts.append(host)
        }

        // A discovered host's *existence* still comes from ~/.ssh/config every launch, so deleting a
        // stanza still removes the host and an override for a host that is gone is simply not applied.
        // What the saved copy carries is the part discovery cannot know: forwards, extra ssh options,
        // whether a password is expected.
        for discovered in discoverSSHHosts() where !hosts.contains(where: { $0.name == discovered.name }) {
            hosts.append(savedById[discovered.id] ?? discovered)
        }

        return hosts
    }

    /// Reads the file, and on a decode failure preserves it instead of letting it be overwritten.
    ///
    /// Both halves used to be `try?` with no fallback, which turned a truncated or hand-mangled file
    /// into "the user has no hosts" with nothing said — and then the first edit did load-modify-save
    /// and wrote a single host over the file that still had the rest. Renaming it aside costs nothing
    /// and means the bad state is recoverable by hand, which is the only thing that can be promised
    /// once the contents are unreadable.
    private func loadSaved() -> [StoredHost] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            loadFailure = nil
            return []
        }
        do {
            let data = try Data(contentsOf: storeURL)
            // A zero-length file is what an interrupted write leaves behind. Not an error worth
            // preserving, and not something to decode either.
            guard !data.isEmpty else {
                loadFailure = nil
                return []
            }
            let saved = try JSONDecoder().decode([StoredHost].self, from: data)
            loadFailure = nil
            return saved
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = storeURL.deletingLastPathComponent()
                .appendingPathComponent("hosts.json.corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: storeURL, to: aside)
            loadFailure = "\(storeURL.lastPathComponent) could not be read (\(error.localizedDescription)). "
                + "It has been kept as \(aside.lastPathComponent); saved hosts are not in this list."
            return []
        }
    }

    public func saveHosts(_ hosts: [StoredHost]) throws {
        // "local" is implicit, and a discovered host is re-derived from ~/.ssh/config on each launch —
        // persisting an unedited one would leave a stale entry behind when the file changes.
        //
        // An *edited* one has to be kept, though, and used not to be: the id keeps its `ssh-` prefix
        // through the editor, so a port forward or an extra ssh option added to a discovered host
        // worked for the rest of the session and was gone on relaunch, while the Keychain item it
        // wrote survived — leaving the flag and the secret disagreeing. Only the difference from what
        // discovery produces is stored, so ~/.ssh/config stays authoritative for everything untouched.
        var discovered: [String: StoredHost] = [:]
        for host in discoverSSHHosts() where discovered[host.id] == nil { discovered[host.id] = host }

        let persisted = hosts.filter { host in
            guard host.id != "local" else { return false }
            guard host.id.hasPrefix("ssh-") else { return true }
            // Only an override for a stanza that is still there. An entry whose `Host` block has gone
            // would never be shown again anyway — `loadHosts` applies these to discovered hosts and
            // never resurrects one — so keeping it would be the stale entry this filter exists to
            // prevent.
            guard let baseline = discovered[host.id] else { return false }
            return baseline != host
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persisted).write(to: storeURL, options: .atomic)
    }

    /// Host *names* only, from `Host` stanzas without wildcards. Resolution of what those names
    /// mean is left to `ssh -G`; `~/.ssh/config` is not a format worth reimplementing (§2.3).
    private func discoverSSHHosts() -> [StoredHost] {
        guard let contents = try? String(contentsOf: sshConfigURL, encoding: .utf8) else { return [] }

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
