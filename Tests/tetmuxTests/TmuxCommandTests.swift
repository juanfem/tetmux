import XCTest
@testable import tetmuxCore

final class TmuxCommandTests: XCTestCase {

    // MARK: - Quoting

    func testQuotingWrapsAndEscapes() {
        XCTAssertEqual(TmuxCommand.quote("build"), "'build'")
        XCTAssertEqual(TmuxCommand.quote("my session"), "'my session'")
        XCTAssertEqual(TmuxCommand.quote("it's"), #"'it'\''s'"#)
    }

    /// A session name is user data. Unquoted interpolation makes `kill-session -t $(...)` a command
    /// injection into the user's own shell on the far end.
    func testQuotingNeutralisesShellMetacharacters() {
        for hostile in ["a; rm -rf /", "$(whoami)", "`id`", "a && b", "*", "a\\b", "--flag"] {
            let quoted = TmuxCommand.quote(hostile)
            XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
            // Every embedded quote is closed and reopened, so the value can never end the literal
            // early and start a new word.
            let interior = quoted.dropFirst().dropLast()
            XCTAssertFalse(interior.contains("'") && !quoted.contains(#"'\''"#))
        }
    }

    // MARK: - Single-line sanitisation

    func testSingleLineLeavesOrdinaryNamesAlone() {
        XCTAssertEqual(TmuxCommand.singleLine("build"), "build")
        XCTAssertEqual(TmuxCommand.singleLine("api server"), "api server")
        XCTAssertEqual(TmuxCommand.singleLine("  padded  "), "padded")
        XCTAssertEqual(TmuxCommand.singleLine("naïve — 日本語 🙂"), "naïve — 日本語 🙂")
    }

    /// Control-mode commands are framed by newlines, so a name carrying one ends the command before
    /// tmux's parser reaches the closing quote — and the remainder arrives as a *new* command.
    /// `quote` cannot defend against this, because the framing is resolved a layer below the parser.
    func testSingleLineNeutralisesCommandFraming() {
        XCTAssertEqual(TmuxCommand.singleLine("api\nkill-server"), "api kill-server")
        // CRLF is a single grapheme cluster, so it collapses to one space rather than two.
        XCTAssertEqual(TmuxCommand.singleLine("api\r\nkill-server"), "api kill-server")
        XCTAssertEqual(TmuxCommand.singleLine("api\u{1b}kill"), "api kill")

        for hostile in ["a\nkill-server", "a\rb", "a\u{0}b", "\nkill-server\n", "a\u{1b}[31m"] {
            let sanitised = TmuxCommand.singleLine(hostile)
            XCTAssertFalse(sanitised.contains(where: \.isNewline), sanitised.debugDescription)
            XCTAssertFalse(
                sanitised.unicodeScalars.contains { $0.properties.generalCategory == .control },
                sanitised.debugDescription
            )
        }
    }

    // MARK: - Double-quoted literals (paste)

    /// Expectations here are ground truth from tmux 3.7b's own lexer, exercised over a control-mode
    /// channel — the only place tmux quoting is parsed at all. A shell cannot answer the question,
    /// because argv arrives pre-split.
    func testDoubleQuotedEncodesNewlinesRatherThanEndingTheCommand() {
        XCTAssertEqual(TmuxCommand.doubleQuoted("plain"), "\"plain\"")
        XCTAssertEqual(TmuxCommand.doubleQuoted("line1\nline2"), #""line1\nline2""#)
        XCTAssertEqual(TmuxCommand.doubleQuoted("line1\r\nline2"), #""line1\r\nline2""#)
        XCTAssertEqual(TmuxCommand.doubleQuoted("bare\rcr"), #""bare\rcr""#)
    }

    /// tmux expands `$VAR` inside double quotes, so pasting a shell snippet would otherwise arrive with
    /// the *local* value substituted — wrong, and a way to leak local environment to a remote host.
    func testDoubleQuotedNeutralisesExpansion() {
        XCTAssertEqual(TmuxCommand.doubleQuoted("cd $HOME"), #""cd \$HOME""#)
        XCTAssertEqual(TmuxCommand.doubleQuoted("${SECRET}"), #""\${SECRET}""#)
        // Two hashes: `\#` is the escape introducer inside a single-hash raw string.
        XCTAssertEqual(TmuxCommand.doubleQuoted("#{session_name}"), ##""\#{session_name}""##)
        XCTAssertEqual(TmuxCommand.doubleQuoted(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(TmuxCommand.doubleQuoted(#"a\b"#), #""a\\b""#)
    }

    /// The invariant that actually matters: whatever comes out cannot end the command it is embedded in.
    func testDoubleQuotedNeverEmitsARawNewline() {
        let hostile = [
            "a\nb", "a\r\nb", "\n", "\r", "a\nkill-server\n",
            #"$(id)"#, "\u{1b}[31mred", "tab\tseparated", "NUL\0inside", "🙂\u{200d}🙂 日本語",
        ]
        for text in hostile {
            let encoded = TmuxCommand.doubleQuoted(text)
            XCTAssertFalse(encoded.contains(where: \.isNewline), encoded.debugDescription)
            XCTAssertTrue(encoded.hasPrefix("\"") && encoded.hasSuffix("\""), encoded.debugDescription)
        }
    }

    /// Control characters other than the framing ones survive verbatim — verified for ESC, 0x01 and
    /// 0x7f against the real lexer. NUL cannot: tmux reads commands as C strings, so it is dropped
    /// rather than silently truncating the rest of the paste.
    func testDoubleQuotedPassesControlBytesButDropsNul() {
        XCTAssertEqual(TmuxCommand.doubleQuoted("a\u{1b}b"), "\"a\u{1b}b\"")
        XCTAssertEqual(TmuxCommand.doubleQuoted("a\u{01}b"), "\"a\u{01}b\"")
        XCTAssertEqual(TmuxCommand.doubleQuoted("a\u{7f}b"), "\"a\u{7f}b\"")
        XCTAssertEqual(TmuxCommand.doubleQuoted("a\0b"), "\"ab\"")
    }

    // MARK: - Chunking

    func testChunkingReassemblesExactly() {
        let text = String(repeating: "abcdef\n", count: 500) + "🙂 tail"
        let chunks = TmuxCommand.chunk(text, maxEscapedBytes: 64)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
    }

    /// A boundary through a multi-byte scalar or a grapheme cluster would put mojibake in the middle of
    /// the paste, so chunks are only ever cut between `Character`s.
    func testChunkingNeverSplitsACharacter() {
        // Family emoji: one grapheme, many scalars, well over any small budget.
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 20)
        let chunks = TmuxCommand.chunk(text, maxEscapedBytes: 16)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty)
            XCTAssertEqual(chunk, String(chunk.map { $0 }), "a chunk boundary fell inside a character")
            XCTAssertTrue(chunk.allSatisfy { $0 == "👨‍👩‍👧‍👦" }, chunk.debugDescription)
        }
    }

    func testChunkingShortTextIsOneChunk() {
        XCTAssertEqual(TmuxCommand.chunk("short", maxEscapedBytes: 4096), ["short"])
        XCTAssertEqual(TmuxCommand.chunk("", maxEscapedBytes: 4096), [])
    }

    // MARK: - Local invocation

    func testLocalArgumentsRequestControlMode() {
        let args = TmuxCommand.localArguments(mode: .createOrAttach(sessionName: "work"))
        XCTAssertEqual(Array(args[0..<3]), ["-CC", "-2", "-u"])
        XCTAssertEqual(args, ["-CC", "-2", "-u", "new-session", "-A", "-s", "work"])
    }

    func testLocalAttachOnlyDoesNotCreate() {
        // F4.15: reconnection must never create a session.
        let args = TmuxCommand.localArguments(mode: .attach(sessionName: "work"))
        XCTAssertTrue(args.contains("attach-session"))
        XCTAssertFalse(args.contains("new-session"))
    }

    // MARK: - Remote invocation

    /// The remote regression. `ssh host -- sh -c "a b c"` does not run `a b c`: ssh joins every
    /// argument after the destination with spaces and hands the single resulting string to the
    /// remote login shell, so `sh -c` gets only the next word and everything else becomes
    /// positional arguments. tmux never launched.
    func testRemoteCommandIsExactlyOneArgument() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox",
            port: nil,
            controlPath: "/tmp/tetmux/cm-%C",
            remoteCommand: TmuxCommand.remoteCommand(mode: .createOrAttach(sessionName: "work"))
        )
        guard let separator = args.firstIndex(of: "--") else { return XCTFail("expected a -- separator") }
        XCTAssertEqual(
            args.count - separator - 1, 1,
            "everything after -- must be a single argument; ssh concatenates the rest"
        )
        XCTAssertEqual(args[separator - 1], "devbox", "the destination must precede --")
    }

    func testRemoteCommandLaunchesTmuxInControlMode() {
        let command = TmuxCommand.remoteCommand(mode: .createOrAttach(sessionName: "work"))
        XCTAssertTrue(command.contains("exec tmux -CC -2 -u new-session -A -s 'work'"), command)
        XCTAssertTrue(command.contains("command -v tmux"), "a missing remote tmux must say so")
        XCTAssertTrue(command.contains("/opt/homebrew/bin"), "non-interactive shells miss Homebrew")
    }

    func testRemoteSessionNameIsQuoted() {
        let command = TmuxCommand.remoteCommand(mode: .attach(sessionName: "my project"))
        XCTAssertTrue(command.contains("attach-session -t 'my project'"), command)
    }

    // MARK: - Attaching to whatever is left

    /// The mode the recovery from `%exit` uses. It must name no session at all: it exists for the
    /// case where the remembered name refers to a session that has just been destroyed, and any form
    /// of `new-session` there recreates exactly the thing the user closed.
    func testAttachAnyNamesNoSessionAndCreatesNothing() {
        let local = TmuxCommand.localArguments(mode: .attachAny)
        XCTAssertEqual(local, ["-CC", "-2", "-u", "attach-session"])
        XCTAssertFalse(local.contains("new-session"))
        XCTAssertFalse(local.contains("-t"), "attachAny must not target a session by name")

        let remote = TmuxCommand.remoteCommand(mode: .attachAny)
        XCTAssertTrue(remote.contains("exec tmux -CC -2 -u attach-session"), remote)
        XCTAssertFalse(remote.contains("new-session"))
        XCTAssertFalse(remote.contains("-t "), remote)
    }

    /// A session name that looks like a flag is still a name. The quoting is per case rather than a
    /// filter over the argument list precisely so this cannot be mistaken for one.
    func testASessionNameResemblingAFlagIsStillQuoted() {
        XCTAssertTrue(
            TmuxCommand.remoteCommand(mode: .attach(sessionName: "-d")).contains("attach-session -t '-d'"),
            "a name beginning with a dash must reach tmux quoted"
        )
    }

    func testSshArgumentsUseTheStandardInvocation() {
        let args = TmuxCommand.sshArguments(
            destination: "user@devbox", port: 2222,
            controlPath: "/tmp/tetmux/cm-%C", remoteCommand: "true"
        )
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("ControlMaster=auto"))
        XCTAssertTrue(joined.contains("ControlPersist=300"))
        XCTAssertTrue(joined.contains("ServerAliveInterval=15"))
        XCTAssertTrue(joined.contains("ServerAliveCountMax=3"))
        XCTAssertTrue(args.contains("-tt"), "tmux refuses to attach without a terminal")
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
    }

    /// §2.3 — the application never weakens host-key checking, and never auto-accepts a key.
    func testSshArgumentsNeverDisableHostKeyChecking() {
        let joined = TmuxCommand.sshArguments(
            destination: "devbox", port: nil,
            controlPath: "/tmp/cm-%C", remoteCommand: "true"
        ).joined(separator: " ")
        XCTAssertFalse(joined.contains("StrictHostKeyChecking"))
        XCTAssertFalse(joined.contains("UserKnownHostsFile"))
    }

    // MARK: - Port forwards

    func testForwardSpecifications() {
        let local = PortForward(kind: .local, listenPort: 8080, destinationHost: "localhost", destinationPort: 80)
        XCTAssertEqual(local.specification, "8080:localhost:80")

        let bound = PortForward(
            kind: .local, bindAddress: "127.0.0.1", listenPort: 5432,
            destinationHost: "db.internal", destinationPort: 5432
        )
        XCTAssertEqual(bound.specification, "127.0.0.1:5432:db.internal:5432")

        let remote = PortForward(kind: .remote, listenPort: 9000, destinationHost: "localhost", destinationPort: 3000)
        XCTAssertEqual(remote.specification, "9000:localhost:3000")

        // A SOCKS proxy has no destination; it decides per connection.
        let socks = PortForward(kind: .dynamic, listenPort: 1080)
        XCTAssertEqual(socks.specification, "1080")
        XCTAssertTrue(socks.isValid, "-D needs no destination")
    }

    /// An IPv6 literal's colons would otherwise be read as the specification's field separators.
    func testIPv6LiteralsAreBracketed() {
        let forward = PortForward(
            kind: .local, bindAddress: "::1", listenPort: 8080,
            destinationHost: "fe80::1", destinationPort: 80
        )
        XCTAssertEqual(forward.specification, "[::1]:8080:[fe80::1]:80")

        // Already bracketed input is left alone rather than double-wrapped.
        let explicit = PortForward(kind: .local, bindAddress: "[::1]", listenPort: 1, destinationHost: "a", destinationPort: 2)
        XCTAssertEqual(explicit.specification, "[::1]:1:a:2")
    }

    func testInvalidForwardsAreRejected() {
        // A half-filled row from the editor.
        XCTAssertFalse(PortForward(kind: .local, listenPort: 0, destinationHost: "localhost", destinationPort: 80).isValid)
        XCTAssertFalse(PortForward(kind: .local, listenPort: 8080, destinationHost: "", destinationPort: 80).isValid)
        XCTAssertFalse(PortForward(kind: .local, listenPort: 8080, destinationHost: "localhost", destinationPort: 0).isValid)
        XCTAssertFalse(PortForward(kind: .local, listenPort: 70000, destinationHost: "localhost", destinationPort: 80).isValid)
        // Whitespace would split the specification into two argv words.
        XCTAssertFalse(PortForward(kind: .local, listenPort: 80, destinationHost: "a b", destinationPort: 80).isValid)
        XCTAssertFalse(PortForward(kind: .dynamic, bindAddress: "a b", listenPort: 1080).isValid)
        XCTAssertFalse(PortForward(kind: .local, listenPort: 80, destinationHost: "a\nb", destinationPort: 80).isValid)
    }

    /// A malformed forward makes ssh exit before tmux ever starts, so incomplete rows are dropped
    /// rather than passed through — the session matters more than the tunnel.
    func testForwardArgumentsSkipIncompleteEntries() {
        let args = TmuxCommand.forwardArguments([
            PortForward(kind: .local, listenPort: 8080, destinationHost: "localhost", destinationPort: 80),
            PortForward(kind: .local, listenPort: 0, destinationHost: "", destinationPort: 0),
            PortForward(kind: .dynamic, listenPort: 1080),
        ])
        XCTAssertEqual(args, ["-L", "8080:localhost:80", "-D", "1080"])
    }

    func testSshArgumentsCarryForwardsAndKeepTheRemoteCommandLast() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true",
            forwards: [
                PortForward(kind: .local, listenPort: 8080, destinationHost: "localhost", destinationPort: 80),
                PortForward(kind: .remote, listenPort: 9000, destinationHost: "localhost", destinationPort: 3000),
            ]
        )
        XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "8080:localhost:80")
        XCTAssertEqual(args[args.firstIndex(of: "-R")! + 1], "9000:localhost:3000")

        // The remote command must still be the single last element (ssh joins everything after the
        // destination), and forwards must not have displaced it.
        let separator = try! XCTUnwrap(args.firstIndex(of: "--"))
        XCTAssertEqual(args.count - separator - 1, 1)
        XCTAssertEqual(args[separator - 1], "devbox")

        // A forward that cannot bind must not take the session down with it.
        XCTAssertFalse(args.joined(separator: " ").contains("ExitOnForwardFailure"))
    }

    /// F4.14 one layer down: ssh gets one password attempt, so a rejected password cannot be
    /// resubmitted into a lockout.
    func testPasswordHostsGetASinglePromptAndNoWeakenedChecking() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true",
            expectsPasswordPrompt: true
        )
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("NumberOfPasswordPrompts=1"), joined)
        XCTAssertFalse(joined.contains("StrictHostKeyChecking"))
        XCTAssertFalse(joined.contains("UserKnownHostsFile"))
        // Key authentication is still ssh's decision, not ours to disable.
        XCTAssertFalse(joined.contains("PubkeyAuthentication"))
        XCTAssertFalse(joined.contains("PreferredAuthentications"))

        // And nothing is added for a host that does not expect a prompt.
        let plain = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true"
        ).joined(separator: " ")
        XCTAssertFalse(plain.contains("NumberOfPasswordPrompts"))
    }

    // MARK: - User-supplied ssh options

    /// Typed-in options are split the way a shell would split them, because that is how they are
    /// typed — but nothing else a shell does happens to them.
    func testExtraArgumentsAreSplitLikeAShellWouldSplitThem() {
        XCTAssertEqual(TmuxCommand.splitArguments("-C -o Compression=yes"), ["-C", "-o", "Compression=yes"])
        XCTAssertEqual(TmuxCommand.splitArguments("   -4\t\t-A  "), ["-4", "-A"])
        XCTAssertEqual(TmuxCommand.splitArguments(""), [])

        // A value with a space in it is the reason quoting has to be understood at all.
        XCTAssertEqual(
            TmuxCommand.splitArguments("-o \"ProxyCommand=nc %h %p\""),
            ["-o", "ProxyCommand=nc %h %p"]
        )
        XCTAssertEqual(TmuxCommand.splitArguments("-o 'RemoteCommand=a b'"), ["-o", "RemoteCommand=a b"])
        XCTAssertEqual(TmuxCommand.splitArguments(#"-i /path/with\ space/key"#), ["-i", "/path/with space/key"])
        // Being edited a keystroke at a time, so half a quoted value is a normal thing to hold.
        XCTAssertEqual(TmuxCommand.splitArguments("-o \"Proxy"), ["-o", "Proxy"])
        XCTAssertEqual(TmuxCommand.splitArguments("-o \"\""), ["-o", ""])
    }

    /// Splitting is all that happens: no expansion, no substitution, no shell. A value that looks
    /// like a command stays one argument and reaches `execve` as text.
    func testExtraArgumentsAreNeverExpanded() {
        XCTAssertEqual(TmuxCommand.splitArguments("-o Foo=$HOME"), ["-o", "Foo=$HOME"])
        XCTAssertEqual(TmuxCommand.splitArguments("-o Foo=`id`"), ["-o", "Foo=`id`"])
        XCTAssertEqual(TmuxCommand.splitArguments("-o Foo=a;rm -rf ~"), ["-o", "Foo=a;rm", "-rf", "~"])
    }

    /// ssh resolves each parameter to the *first* value it obtains, so the user's options have to
    /// precede tetmux's or an `-o` in this field would be accepted and then quietly ignored.
    func testExtraArgumentsPrecedeTheDefaultsSoTheyCanOverrideThem() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true",
            extraArguments: ["-o", "ServerAliveInterval=60"]
        )
        let mine = try! XCTUnwrap(args.firstIndex(of: "ServerAliveInterval=60"))
        let ours = try! XCTUnwrap(args.firstIndex(of: "ServerAliveInterval=15"))
        XCTAssertLessThan(mine, ours, "a later -o is the one ssh discards")

        // And the remote command is still the single last element.
        let separator = try! XCTUnwrap(args.firstIndex(of: "--"))
        XCTAssertEqual(args.count - separator - 1, 1)
    }

    func testX11ForwardingIsOptIn() {
        let plain = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true"
        )
        XCTAssertFalse(plain.contains("-X"))
        XCTAssertFalse(plain.contains("-Y"), "trusted forwarding is never implied")

        let forwarding = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true",
            forwardsX11: true
        )
        XCTAssertTrue(forwarding.contains("-X"))
        XCTAssertFalse(forwarding.contains("-Y"))
    }

    func testDefaultPortIsLeftToSshConfig() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox", port: 22,
            controlPath: "/tmp/cm-%C", remoteCommand: "true"
        )
        XCTAssertFalse(args.contains("-p"), "port 22 is the default; ~/.ssh/config may override it")
    }
}

final class TmuxVersionTests: XCTestCase {

    func testParsesReleaseForms() {
        XCTAssertEqual(TmuxVersion("3.4")?.major, 3)
        XCTAssertEqual(TmuxVersion("3.4")?.minor, 4)
        // Letter suffixes are the norm for tmux point releases.
        XCTAssertEqual(TmuxVersion("3.7b")?.minor, 7)
        XCTAssertEqual(TmuxVersion("next-3.6")?.minor, 6)
        XCTAssertEqual(TmuxVersion("3")?.minor, 0)
        XCTAssertEqual(TmuxVersion(" 2.9a\n")?.raw, "2.9a")
        XCTAssertNil(TmuxVersion("master"))
    }

    func testOrdering() {
        XCTAssertLessThan(TmuxVersion("2.9")!, TmuxVersion("3.0")!)
        XCTAssertLessThan(TmuxVersion("3.2")!, TmuxVersion("3.10")!)
        XCTAssertEqual(TmuxVersion("3.7b")!, TmuxVersion("3.7")!)
    }

    /// §3.4 — the feature floor table.
    func testFeatureFloors() {
        XCTAssertTrue(TmuxVersion("3.2")!.supportsSubscriptions)
        XCTAssertTrue(TmuxVersion("3.7b")!.supportsSubscriptions)
        XCTAssertFalse(TmuxVersion("3.1")!.supportsSubscriptions)

        XCTAssertTrue(TmuxVersion("2.4")!.supportsControlMode)
        XCTAssertFalse(TmuxVersion("2.3")!.supportsControlMode)
        XCTAssertFalse(TmuxVersion("1.8")!.supportsControlMode)

        // Flow control — `pause-after`, `refresh-client -A`, `%pause`/`%continue` — arrived in 3.2.
        XCTAssertTrue(TmuxVersion("3.2")!.supportsFlowControl)
        XCTAssertTrue(TmuxVersion("3.7b")!.supportsFlowControl)
        XCTAssertFalse(TmuxVersion("3.1")!.supportsFlowControl)
        XCTAssertFalse(TmuxVersion("2.9")!.supportsFlowControl)
    }
}

/// P6.5 — the command forms backpressure is built out of.
final class FlowControlCommandTests: XCTestCase {

    func testPauseAfterFlagUsesTheClientFlagForm() {
        XCTAssertEqual(TmuxCommand.pauseAfterFlag(seconds: 3), "refresh-client -f pause-after=3")
    }

    /// `pause-after=0` is not "never pause" — it is a client that is always behind, which pauses
    /// every pane immediately and freezes the whole UI.
    func testPauseAfterFlagNeverAsksForZeroSeconds() {
        XCTAssertEqual(TmuxCommand.pauseAfterFlag(seconds: 0), "refresh-client -f pause-after=1")
        XCTAssertEqual(TmuxCommand.pauseAfterFlag(seconds: -5), "refresh-client -f pause-after=1")
    }

    /// The argument is one `pane:state` word, so it has to be quoted as one — and the pane id keeps
    /// its `%` sigil, which is what tmux matches on.
    func testFlowControlAddressesAPaneByItsSigilledId() {
        XCTAssertEqual(TmuxCommand.flowControl(paneId: "%7", paused: true), "refresh-client -A '%7:pause'")
        XCTAssertEqual(TmuxCommand.flowControl(paneId: "%7", paused: false), "refresh-client -A '%7:continue'")
    }
}

final class TmuxWindowTests: XCTestCase {

    func testApplyingALayoutPopulatesPanes() {
        var window = TmuxWindow(id: "@1", name: "zsh")
        window.apply(layoutString: "273c,200x50,0,0{100x50,0,0,23,99x50,101,0[99x25,101,0,24,99x24,101,26,25]}")

        XCTAssertEqual(window.panes.map(\.id), ["%23", "%24", "%25"])
        XCTAssertEqual(window.paneCount, 3)
        XCTAssertEqual(window.panes[0].cols, 100)
        XCTAssertEqual(window.panes[1].rows, 25)
        XCTAssertEqual(window.activePaneId, "%23")
    }

    func testApplyingANewLayoutDropsClosedPanes() {
        var window = TmuxWindow(id: "@1", name: "zsh")
        window.apply(layoutString: "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}")
        window.activePaneId = "%21"

        window.apply(layoutString: "d95f,80x24,0,0,20")

        XCTAssertEqual(window.panes.map(\.id), ["%20"])
        XCTAssertEqual(window.activePaneId, "%20", "focus must move off the pane that went away")
    }

    func testUnparseableLayoutLeavesTheWindowUsable() {
        var window = TmuxWindow(id: "@1", name: "zsh", activePaneId: "%5")
        window.apply(layoutString: "not a layout")
        XCTAssertNil(window.layoutTree)
        XCTAssertEqual(window.preferredPaneId, "%5", "the surface still has a pane to bind to")
    }

    /// R3.5, and the reason it can be switched on at the production callers: a layout whose checksum
    /// does not match its body is not applied *at all* — the window keeps the last one that did, so
    /// the worst case is a stale grid rather than the blank window a `nil` tree renders.
    func testALayoutWhoseChecksumDoesNotMatchIsRejectedAndTheOldOneSurvives() {
        var window = TmuxWindow(id: "@1", name: "zsh")
        let good = "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}"
        XCTAssertEqual(window.apply(layoutString: good), .applied)

        // Same body as the single-pane layout above, with one hex digit of its prefix changed.
        let outcome = window.apply(layoutString: "e95f,80x24,0,0,20")
        guard case .rejected = outcome else {
            return XCTFail("expected .rejected, got \(outcome)")
        }
        XCTAssertEqual(window.layoutString, good, "the string and the tree must not come apart")
        XCTAssertEqual(window.panes.map(\.id), ["%20", "%21"])
        XCTAssertEqual(window.layoutTree?.paneIds, ["%20", "%21"])
    }

    /// The two fields describe one window and arrive in one notification, so a visible layout that
    /// fails to parse must take the whole update down with it. Applying the full layout alone would
    /// set `isZoomed` with no visible tree, and `renderTree` would fall back to the unzoomed grid —
    /// which is the wrapped-and-truncated failure the visible layout exists to prevent.
    func testAnUnparseableVisibleLayoutRejectsTheWholeUpdate() {
        var window = TmuxWindow(id: "@1", name: "zsh")
        window.apply(layoutString: "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}")

        let outcome = window.apply(
            layoutString: "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}",
            visibleLayout: "0000,80x24,0,0,20",
            flags: "Z*"
        )
        guard case .rejected = outcome else {
            return XCTFail("expected .rejected, got \(outcome)")
        }
        XCTAssertFalse(window.isZoomed, "zoom must not be recorded without the grid that goes with it")
        XCTAssertEqual(window.renderTree?.paneIds, ["%20", "%21"])
    }

    /// Every checksum tmux itself emitted must pass, or switching verification on costs the user
    /// their panes on the first notification. These are captured strings, zoomed one included.
    func testRealTmuxLayoutsAllPassChecksumVerification() {
        let captured = [
            "5967,80x24,0,0,18",
            "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}",
            "273c,200x50,0,0{100x50,0,0,23,99x50,101,0[99x25,101,0,24,99x24,101,26,25]}",
            "9d29,200x50,0,0[200x25,0,0,0,200x24,0,26{100x24,0,26,1,99x24,101,26[99x12,101,26,2,99x11,101,39,3]}]",
            // `#{window_visible_layout}` for the one above, with pane 3 zoomed.
            "aca0,200x50,0,0,3",
        ]
        for layout in captured {
            var window = TmuxWindow(id: "@1", name: "zsh")
            XCTAssertEqual(window.apply(layoutString: layout), .applied, layout)
        }
    }
}
