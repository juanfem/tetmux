import Foundation

/// The relay's own ssh keys: the ones `ssh` offers when the relay connects to a host, which are the
/// ones a host's `authorized_keys` has to list. Not the keys of whichever machine the person reading
/// the page is on — copying that one into `authorized_keys` is the easy mistake this exists to avoid.
///
/// Only the default identity files are looked at. A host whose `~/.ssh/config` stanza names an
/// `IdentityFile` uses that one, and the page says so rather than guessing.
enum RelayKey {
    struct Key: Encodable, Equatable {
        /// Where it lives on the server, `~/.ssh/id_ed25519.pub`.
        let path: String
        /// The `.pub` line, as it goes into `authorized_keys`.
        let key: String
    }

    enum Failure: Error, CustomStringConvertible {
        case exists(String)
        case failed(String)

        var description: String {
            switch self {
            case .exists(let path): return "\(path) already exists; not replacing it"
            case .failed(let why): return "could not make a key: \(why)"
            }
        }
    }

    /// ssh's own order of default identities (`ssh(1)`, `-i`).
    static let defaultNames = ["id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk"]

    static func sshDirectory(home: URL) -> URL {
        home.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Every default identity with both halves present. A `.pub` without its private key is a key
    /// ssh cannot use, and listing it would send someone to authorise a key nothing offers.
    static func find(home: URL) -> [Key] {
        let directory = sshDirectory(home: home)
        return defaultNames.compactMap { name in
            let secret = directory.appendingPathComponent(name)
            let pub = directory.appendingPathComponent(name + ".pub")
            guard FileManager.default.fileExists(atPath: secret.path),
                  let text = try? String(contentsOf: pub, encoding: .utf8) else { return nil }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return Key(path: "~/.ssh/\(name).pub", key: line)
        }
    }

    /// Makes `~/.ssh/id_ed25519`, with no passphrase: the relay runs unattended, and a passphrase
    /// nobody is there to type is a key that never works. Never overwrites — `ssh-keygen` would ask,
    /// and there is no one to answer, so an existing file is refused before it is run.
    static func generate(home: URL, comment: String) throws -> Key {
        let directory = sshDirectory(home: home)
        let secret = directory.appendingPathComponent("id_ed25519")
        for path in [secret.path, secret.path + ".pub"] where FileManager.default.fileExists(atPath: path) {
            throw Failure.exists(path)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Failure.failed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Each value one argv element; `comment` is the machine's name, and no shell sees any of it.
        process.arguments = ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", secret.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw Failure.failed("ssh-keygen did not start: \(error.localizedDescription)")
        }
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(text.isEmpty ? "ssh-keygen exited \(process.terminationStatus)" : text)
        }
        guard let key = find(home: home).first(where: { $0.path == "~/.ssh/id_ed25519.pub" }) else {
            throw Failure.failed("ssh-keygen succeeded but left no ~/.ssh/id_ed25519.pub")
        }
        return key
    }
}
