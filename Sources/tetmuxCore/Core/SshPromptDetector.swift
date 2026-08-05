import Foundation

/// Recognises the prompts `ssh` writes to the tty before the tmux protocol starts.
///
/// A pure function over bytes, like `ControlCodec` and for the same reason: the interesting cases are
/// real transcripts from real servers, and they are only cheap to test if nothing here does I/O.
///
/// Everything this looks at arrives *before* the first `%begin`, which is the same window
/// `Connection.preHandshakeLog` captures. Anything it does not recognise stays unrecognised and ends
/// up in that transcript verbatim (§7) — misreading a prompt is worse than missing one, because the
/// answer to a prompt is a secret and the wrong prompt is the wrong place to send it.
public enum SshPromptDetector {
    /// How far back to look. A prompt is the last thing on the channel when it is pending, and
    /// bounding the window keeps a chatty login banner from being re-scanned on every read.
    private static let tailBytes = 512

    /// The prompt ssh is currently waiting on, if the tail of the stream ends in one.
    ///
    /// Requires the buffer to *end* at the prompt: ssh writes the prompt and then blocks on the tty
    /// without a trailing newline, so "ends with a colon and no newline after it" is precisely the
    /// signal that input is being waited for. A `password:` mentioned in a login banner is followed
    /// by a newline and is therefore correctly ignored.
    public static func pendingPrompt(in bytes: [UInt8]) -> AuthenticationPrompt.Kind? {
        guard let line = trailingLine(in: bytes) else { return nil }
        let lowered = line.lowercased()

        // "Enter passphrase for key '/Users/me/.ssh/id_ed25519':" — belongs to the key, not the host.
        if lowered.contains("passphrase for") || lowered.hasSuffix("passphrase:") {
            return .keyPassphrase
        }

        // "me@host's password:", "Password:", "(me@host) Password:" from PAM keyboard-interactive,
        // "Password for me@host:" from some sshd configurations. Deliberately broad within lines that
        // both mention a password and end in a colon: the shapes vary per PAM stack, and the cost of
        // missing one is a GUI that hangs on a prompt nobody can see.
        if lowered.contains("password"), lowered.hasSuffix(":") {
            return .password
        }

        // First contact with a host key. Captured verbatim from OpenSSH against a real server:
        //
        //   The authenticity of host '[host]:2222 ([addr]:2222)' can't be established.
        //   ED25519 key fingerprint is: SHA256:F1eJ…
        //   This key is not known by any other names.
        //   Are you sure you want to continue connecting (yes/no/[fingerprint])?
        //
        // Note what the last line ends in: **`? `**, not a colon. That is why this used to return
        // nil and the channel then hung until the 45 s handshake watchdog killed it, with the
        // question sitting unanswered on a pty nobody was looking at.
        //
        // A *changed* key never arrives here — ssh refuses that outright with `Host key verification
        // failed` rather than asking — so classifying this cannot make it easier to accept one.
        if lowered.contains("continue connecting") || lowered.contains("authenticity of host") {
            return .hostKey
        }
        // ssh's re-ask when the answer was not one of the three it accepts.
        if lowered.contains("please type"), lowered.contains("yes") {
            return .hostKey
        }

        // Anything else ssh has stopped on. The shape cannot be known — a one-time code, a PAM
        // challenge, a `ProxyCommand` asking something of its own — so the test is the *stopping*
        // rather than the wording: a line with no newline after it that ends the way a question ends.
        //
        // This is the case that used to be silence. Misreading a prompt is worse than missing one
        // (the answer to a prompt is a secret), which is why nothing is filled in automatically here
        // and the caller waits for the stream to settle before believing it — a chunk boundary can
        // land mid-line and make an ordinary banner look like it is waiting.
        if line.hasSuffix(":") || line.hasSuffix("?") {
            return .question
        }
        return nil
    }

    /// The last few lines of the stream, for a prompt whose *context* is the answer.
    ///
    /// A host-key confirmation is meaningless without the fingerprint above it, and the fingerprint
    /// is on a different line from the question. Everything here is shown verbatim (§7); nothing is
    /// summarised, because a summary of a fingerprint is a fingerprint nobody can check.
    public static func promptContext(in bytes: [UInt8], lines limit: Int = 6) -> String? {
        let tail = bytes.count > tailBytes ? Array(bytes.suffix(tailBytes)) : bytes
        guard !tail.isEmpty else { return nil }
        let text = String(decoding: tail, as: UTF8.self)
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(limit).joined(separator: "\n")
    }

    /// The verbatim prompt text, for showing the user exactly what ssh asked.
    public static func promptText(in bytes: [UInt8]) -> String? {
        trailingLine(in: bytes)
    }

    /// The last line of the buffer, with no newline after it.
    ///
    /// Decoded lossily on purpose: a prompt is ASCII, and a partial UTF-8 sequence from a chunk
    /// boundary earlier in the banner must not lose the prompt at the end of the buffer.
    private static func trailingLine(in bytes: [UInt8]) -> String? {
        let tail = bytes.count > tailBytes ? Array(bytes.suffix(tailBytes)) : bytes
        guard !tail.isEmpty else { return nil }

        let text = String(decoding: tail, as: UTF8.self)
        // Splitting on `isNewline` covers the CRLF ssh writes to a tty and the bare CR some prompt
        // paths use to rewrite the line — Swift treats CRLF as one grapheme, so neither leaves a
        // stray empty field behind.
        guard let last = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).last
        else { return nil }

        // A trailing newline means whatever that line was, ssh is not sitting on it waiting for input.
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
