import XCTest
@testable import tetmuxCore

/// Fixtures are bytes captured from OpenSSH 9.x driven under a real pty, not hand-written
/// approximations — the same rule the protocol fixtures follow. The details that matter are all
/// things a plausible-looking fake gets wrong: the leading `\r`, the trailing space after the colon,
/// and the absence of any newline at the end.
///
/// **Host identifiers in these captures are substituted** — the hostname, addresses and key
/// fingerprint are documentation-reserved stand-ins for the real server that produced the bytes.
/// Nothing detection depends on is carried by them: they are opaque text between the punctuation
/// that is load-bearing, and the substitutes keep every byte of that punctuation, the bracketed
/// `[host]:port` form ssh prints for a non-default port included. Do not "restore" a real host here
/// when adding a case; capture against your own and substitute the same way.
final class SshPromptDetectorTests: XCTestCase {

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    // MARK: - Password prompts

    /// Captured from `ssh -o PreferredAuthentications=password -tt localhost`.
    func testRecognisesTheRealPasswordPrompt() {
        let captured = bytes("\rme@localhost's password: ")
        XCTAssertEqual(SshPromptDetector.pendingPrompt(in: captured), .password)
        XCTAssertEqual(
            SshPromptDetector.promptText(in: captured),
            "me@localhost's password:",
            "the prompt is shown verbatim, so the account and host stay visible"
        )
    }

    func testRecognisesPromptShapesFromOtherPamStacks() {
        for prompt in [
            "Password:",
            "Password: ",
            "(me@devbox) Password:",
            "me@devbox's password:",
            "Password for me@devbox:",
        ] {
            XCTAssertEqual(
                SshPromptDetector.pendingPrompt(in: bytes(prompt)), .password,
                "did not recognise \(prompt.debugDescription)"
            )
        }
    }

    /// A prompt is pending only when ssh is *sitting* on it — which on a tty means nothing follows it.
    /// A banner that merely mentions a password is followed by a newline.
    func testAPasswordMentionedInABannerIsNotAPrompt() {
        let banner = bytes("""
        Warning: your password expires in 3 days\r
        Last login: Mon Aug  3 09:12:44 2026\r\n
        """)
        XCTAssertNil(SshPromptDetector.pendingPrompt(in: banner))
    }

    // MARK: - Prompts that must not be answered with a password

    /// Captured from `ssh-keygen -y -f <key>`, which uses the same OpenSSH `read_passphrase` path.
    /// A key's passphrase is not the host's password, so it is classified separately and never filled
    /// from a per-host Keychain entry.
    func testRecognisesAKeyPassphrasePrompt() {
        let captured = bytes("Enter passphrase for \"/Users/me/.ssh/id_ed25519\": ")
        XCTAssertEqual(SshPromptDetector.pendingPrompt(in: captured), .keyPassphrase)

        // ssh's own wording differs slightly from ssh-keygen's; both are the same family.
        XCTAssertEqual(
            SshPromptDetector.pendingPrompt(in: bytes("Enter passphrase for key '/Users/me/.ssh/id_rsa': ")),
            .keyPassphrase
        )
    }

    /// §2.3 — the application never auto-accepts a host key. Captured from a connection with an empty
    /// `known_hosts`; it must not be mistaken for something answerable, or tetmux would be typing
    /// secrets at a fingerprint confirmation.
    /// A host-key confirmation is a question with an answer, and it used to be silence.
    ///
    /// Captured against a real server with a scratch `known_hosts`, which is the only way to make
    /// OpenSSH produce a genuine first contact. The detail that made this a bug: the last line ends
    /// in **`? `**, not a colon — so the colon rule missed it, nothing was published, and the channel
    /// hung until the 45 s handshake watchdog killed it with the question sitting unanswered on a pty
    /// nobody was looking at.
    func testClassifiesAHostKeyConfirmation() {
        let captured = bytes(
            "\rThe authenticity of host '[server.example.org]:2222 ([2001:db8::1]:2222)' can't be established.\r\n"
            + "ED25519 key fingerprint is: SHA256:Qk9zR2xhY2VEb2NFeGFtcGxlS2V5MDAwMDAwMDAwMDA\r\n"
            + "This key is not known by any other names.\r\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        )
        XCTAssertEqual(SshPromptDetector.pendingPrompt(in: captured), .hostKey)
        XCTAssertEqual(
            SshPromptDetector.promptText(in: captured),
            "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        )

        // The question alone is not enough to answer it. The fingerprint is on another line, and a
        // dialog that asked someone to trust a key without showing it would be asking for nothing.
        let context = try? XCTUnwrap(SshPromptDetector.promptContext(in: captured))
        XCTAssertEqual(context?.contains("SHA256:Qk9zR2xhY2VEb2NFeGFtcGxlS2V5MDAwMDAwMDAwMDA"), true)
        XCTAssertEqual(context?.contains("authenticity of host"), true)
    }

    /// ssh's re-ask when the answer was not one of the three it takes.
    func testClassifiesTheHostKeyReAsk() {
        XCTAssertEqual(
            SshPromptDetector.pendingPrompt(in: bytes("Please type 'yes', 'no' or the fingerprint: ")),
            .hostKey
        )
    }

    /// A second factor is recognised as *a question*, and never as a password.
    ///
    /// The distinction is the safety property. Classifying it as a password would fill it from the
    /// Keychain, which burns a one-time prompt and fails the login; classifying it as nothing at all
    /// — which is what used to happen — hangs the connection for 45 seconds and then fails it with
    /// no explanation. It is asked, verbatim, and the answer is never stored.
    func testASecondFactorIsAQuestionRatherThanAPassword() {
        for prompt in [
            "Verification code: ",
            "Duo two-factor login for me\r\n\r\nPasscode or option (1-1): ",
            "Enter the 6-digit code from your authenticator app: ",
        ] {
            let kind = SshPromptDetector.pendingPrompt(in: bytes(prompt))
            XCTAssertEqual(kind, .question, prompt)
            XCTAssertNotEqual(kind, .password, "a second factor must never be answered from the Keychain")
        }
    }

    // MARK: - Robustness

    func testEmptyAndProtocolTrafficAreNotPrompts() {
        XCTAssertNil(SshPromptDetector.pendingPrompt(in: []))
        XCTAssertNil(SshPromptDetector.pendingPrompt(in: bytes("\u{1b}P1000p%begin 1 1\r\n")))
    }

    /// The scan is bounded to the tail of the buffer, so a long banner ahead of the prompt cannot
    /// push it out of view.
    func testFindsThePromptAfterALongBanner() {
        let banner = String(repeating: "this is a very long message of the day line\r\n", count: 200)
        let captured = bytes(banner + "\rme@devbox's password: ")
        XCTAssertEqual(SshPromptDetector.pendingPrompt(in: captured), .password)
    }

    /// Bytes arrive in arbitrary chunks, so a partial UTF-8 sequence earlier in the buffer must not
    /// take the prompt down with it.
    func testSurvivesInvalidUtf8EarlierInTheStream() {
        var captured: [UInt8] = [0xff, 0xfe, 0x80]
        captured += bytes("\r\nme@devbox's password: ")
        XCTAssertEqual(SshPromptDetector.pendingPrompt(in: captured), .password)
    }
}
