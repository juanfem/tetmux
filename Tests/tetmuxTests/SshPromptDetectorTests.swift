import XCTest
@testable import tetmuxCore

/// Fixtures are bytes captured from OpenSSH 9.x driven under a real pty, not hand-written
/// approximations — the same rule the protocol fixtures follow. The details that matter are all
/// things a plausible-looking fake gets wrong: the leading `\r`, the trailing space after the colon,
/// and the absence of any newline at the end.
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
    func testDoesNotClassifyAHostKeyConfirmation() {
        let captured = bytes("""
        \rThe authenticity of host '127.0.0.1 (127.0.0.1)' can't be established.\r
        ED25519 key fingerprint is: SHA256:Fe3EpW6lvvjclGD7kDiIK7MRfppuUtwXKP3Gdd3ZiXY\r
        This key is not known by any other names.\r
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """)
        XCTAssertNil(SshPromptDetector.pendingPrompt(in: captured))
        // It is still surfaced verbatim, which is how the user finds out what happened (§7).
        XCTAssertEqual(
            SshPromptDetector.promptText(in: captured),
            "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        )
    }

    /// A second factor is not the account password. Answering it from the Keychain would burn the
    /// prompt and fail the login.
    func testDoesNotClassifyASecondFactorPrompt() {
        XCTAssertNil(SshPromptDetector.pendingPrompt(in: bytes("Verification code: ")))
        XCTAssertNil(SshPromptDetector.pendingPrompt(in: bytes("Duo two-factor login for me\r\n\r\nPasscode or option (1-1): ")))
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
