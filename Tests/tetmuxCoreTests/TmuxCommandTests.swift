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
        XCTAssertEqual(
            args, ["-CC", "-2", "-u", "new-session", "-A", "-s", "work", "-c", "#{HOME}"]
        )
    }

    /// F4.11 on the connect line. The channel's own `new-session -A` is where the *first* session on
    /// a host comes from, and it used to be the one session that ignored the host's start directory
    /// — locally, that meant every session on the machine started in whatever directory the `.app`
    /// was launched from, which for Finder is `/`.
    func testTheConnectLineStartsASessionWhereTheHostSays() {
        XCTAssertEqual(
            TmuxCommand.localArguments(
                mode: .createOrAttach(sessionName: "work"), startDirectory: "/srv/app"
            ),
            ["-CC", "-2", "-u", "new-session", "-A", "-s", "work", "-c", "/srv/app"]
        )
        let remote = TmuxCommand.remoteCommand(
            mode: .createOrAttach(sessionName: "work"), startDirectory: "~/projects"
        )
        XCTAssertTrue(remote.contains("new-session -A -s 'work' -c '#{HOME}/projects'"), remote)
    }

    /// `-c` belongs to `new-session` and to nothing else: the attaching modes have no session to
    /// apply it to, and passing it would be a flag `attach-session` does not take.
    func testOnlyTheCreatingModeCarriesAStartDirectory() {
        for mode in [TmuxCommand.AttachMode.attach(sessionName: "work"), .attachAny] {
            let args = TmuxCommand.localArguments(mode: mode, startDirectory: "/srv/app")
            XCTAssertFalse(args.contains("-c"), "\(mode) must not carry -c")
            let remote = TmuxCommand.remoteCommand(mode: mode, startDirectory: "/srv/app")
            XCTAssertFalse(remote.contains(" -c "), remote)
        }
    }

    /// tmux does **not** expand a tilde in `-c`, and the way it fails is the reason this is pinned:
    /// `new-session -c '~/work'` does not error, it lands in the home directory, because the literal
    /// path does not exist and tmux falls back to `$HOME`. Verified on 3.0, 3.2a, 3.3a, 3.4, 3.5 and
    /// 3.7b. `#{HOME}` is a format, and an unrecognised format name is looked up in the environment
    /// of the server — which on a remote host is the only side that knows where home is.
    func testAStartDirectoryResolvesTildeItselfAndDefaultsToHome() {
        XCTAssertEqual(TmuxCommand.sessionStartDirectory(nil), "#{HOME}")
        XCTAssertEqual(TmuxCommand.sessionStartDirectory(""), "#{HOME}")
        XCTAssertEqual(TmuxCommand.sessionStartDirectory("   "), "#{HOME}")
        XCTAssertEqual(TmuxCommand.sessionStartDirectory("~"), "#{HOME}")
        XCTAssertEqual(TmuxCommand.sessionStartDirectory("~/projects"), "#{HOME}/projects")
        XCTAssertEqual(TmuxCommand.sessionStartDirectory("/srv/app"), "/srv/app")
        // Not a home directory of ours to rewrite: `~ada` is ssh's and the shell's spelling for
        // somebody else's, and tmux would not expand it either. Passed on as typed rather than
        // turned into a path under *this* user's home, which is the one wrong answer available.
        XCTAssertEqual(TmuxCommand.sessionStartDirectory("~ada/src"), "~ada/src")
        // The framing rule every user value gets: a line break would end the command early.
        XCTAssertEqual(TmuxCommand.sessionStartDirectory("/srv\nkill-server"), "/srv kill-server")
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
        XCTAssertTrue(
            command.contains("exec tmux -CC -2 -u new-session -A -s 'work' -c '#{HOME}'"), command
        )
        XCTAssertTrue(command.contains("command -v tmux"), "a missing remote tmux must say so")
        XCTAssertTrue(command.contains("/opt/homebrew/bin"), "non-interactive shells miss Homebrew")
    }

    func testRemoteSessionNameIsQuoted() {
        let command = TmuxCommand.remoteCommand(mode: .attach(sessionName: "my project"))
        XCTAssertTrue(command.contains("attach-session -t 'my project'"), command)
    }

    // MARK: - Discovery (F4.4)

    /// One `-C`, never two, and a format the channel's own parse also reads.
    func testDiscoveryAsksWithoutAttaching() {
        let args = TmuxCommand.discoveryArguments()
        XCTAssertEqual(args, ["-C", "list-sessions", "-F", TmuxCommand.sessionsFormat])
        XCTAssertFalse(args.contains("-CC"), "-CC would attach a client; this must not")
        XCTAssertFalse(args.contains("new-session"), "discovery must never create")
        XCTAssertFalse(args.contains("attach-session"))
    }

    /// The remote half has to close its own stdin. Verified against 3.7b: `tmux -C` reads commands
    /// until its input ends, so without this it prints the answer and then waits forever — and a
    /// probe that hangs is worse than no probe, because nothing above it is watching.
    func testRemoteDiscoveryClosesItsInputAndCannotCreate() {
        let command = TmuxCommand.remoteDiscoveryCommand()
        XCTAssertTrue(command.contains("< /dev/null"), command)
        XCTAssertTrue(command.contains("exec tmux -C list-sessions"), command)
        XCTAssertFalse(command.contains("-CC"), command)
        XCTAssertFalse(command.contains("new-session"), command)
        XCTAssertTrue(command.contains("command -v tmux"), "R3.8's message belongs here too")
    }

    /// F4.4 runs unbidden, so it may not raise a prompt: no tty to ask on, and ssh told not to.
    func testADiscoveryProbeCanNeitherPromptNorTakeATty() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C",
            remoteCommand: TmuxCommand.remoteDiscoveryCommand(),
            expectsPasswordPrompt: true,
            purpose: .discovery
        )
        XCTAssertTrue(args.contains("-T"), "a tty is somewhere to prompt")
        XCTAssertFalse(args.contains("-tt"))
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "-o" && $1 == "BatchMode=yes" })
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "-o" && $1 == "ConnectTimeout=5" })
        // Even for a host that *does* use a password: the prompt cap is about answering one, and
        // this probe must not be offered the chance.
        XCTAssertFalse(args.contains("NumberOfPasswordPrompts=1"))
        // The master socket is the whole reason this is cheap.
        XCTAssertTrue(args.contains("ControlPath=/tmp/cm-%C"))
    }

    /// The invocation the *service* assembles, not the one the builder produces when asked nicely.
    ///
    /// This is the test that was missing, and a real bug went through the gap: `sshArguments` had a
    /// correct `.discovery` branch and `invocation` never passed `purpose:`, so every probe ran as a
    /// channel would — with a tty, without `BatchMode`, and leaving a `ControlPersist` master behind.
    /// On a host that asks for a password that is an authentication attempt nobody can answer, raised
    /// every time a window takes focus, until the server starts refusing the connections the user
    /// actually wants. A unit test of the builder cannot see an argument the caller never supplies.
    func testTheAssembledDiscoveryInvocationCannotPromptOrLeaveAMasterBehind() async throws {
        let service = SessionService()
        let config = HostConfig(
            id: "devbox", name: "devbox", user: "me", port: 2222,
            usesPassword: true, forwards: [
                PortForward(kind: .local, listenPort: 5432, destinationHost: "db", destinationPort: 5432)
            ],
            forwardsX11: true
        )

        let probe = try await service.invocation(for: config, mode: nil, flavour: .discovery)
        XCTAssertEqual(probe.executable, "/usr/bin/ssh")
        let args = probe.arguments
        XCTAssertTrue(args.contains("-T"), "a probe must not take a tty: \(args)")
        XCTAssertFalse(args.contains("-tt"), "a tty is somewhere ssh can prompt: \(args)")
        XCTAssertTrue(args.contains("BatchMode=yes"), "ssh must fail rather than ask: \(args)")
        XCTAssertTrue(args.contains("ControlMaster=no"), "a probe may use a master, never make one")
        XCTAssertFalse(args.contains { $0.hasPrefix("ControlPersist") }, "nothing outlives a probe")
        XCTAssertFalse(args.contains("NumberOfPasswordPrompts=1"), "it may not attempt a password at all")
        // Forwards and X11 belong to the connection the user asked for. On a master they would bind
        // the user's ports from a background probe they cannot see or close.
        XCTAssertFalse(args.contains("-L"), "\(args)")
        XCTAssertFalse(args.contains("-X"), "\(args)")

        // …and the channel for the same host is unchanged by all of it.
        let channel = try await service.invocation(for: config, mode: .attachAny, flavour: .controlMode)
        XCTAssertTrue(channel.arguments.contains("-tt"))
        XCTAssertTrue(channel.arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(channel.arguments.contains("ControlPersist=300"))
        XCTAssertTrue(channel.arguments.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(channel.arguments.contains("-X"))
        XCTAssertTrue(channel.arguments.contains("-L"))
    }

    /// A channel is unchanged by any of it.
    func testAChannelStillTakesATty() {
        let args = TmuxCommand.sshArguments(
            destination: "devbox", port: nil, controlPath: "/tmp/cm-%C", remoteCommand: "true"
        )
        XCTAssertTrue(args.contains("-tt"))
        XCTAssertFalse(args.contains("BatchMode=yes"))
    }

    /// The distinction the whole feature rests on: "this host has nothing" is an answer, and
    /// "we could not ask" is not — and recording the second as the first tells somebody their work
    /// is gone because their laptop is on a train.
    func testAnUnreachableHostIsNotAnEmptyHost() {
        func probe(_ text: String, status: Int32 = 0) -> CommandProbe.Result {
            CommandProbe.Result(status: status, output: Data(text.utf8), timedOut: false)
        }

        let listed = probe("""
        %begin 1785940547 9452 0\r
        $2|0|work\r
        $0|1|scratch\r
        %end 1785940547 9452 0\r
        %exit\r

        """)
        let sessions = try? XCTUnwrap(SessionService.parseDiscovery(listed))
        XCTAssertEqual(sessions?.map(\.name), ["scratch", "work"], "sorted by name, as the tree shows them")
        XCTAssertEqual(sessions?.first { $0.name == "scratch" }?.isAttached, true)
        XCTAssertTrue(sessions?.allSatisfy { $0.windows.isEmpty } == true, "a probe asks one question")

        // tmux answered, and the answer is "nothing here" — which must supersede whatever a dead
        // channel left listed.
        XCTAssertEqual(
            SessionService.parseDiscovery(
                probe("no server running on /private/tmp/tmux-501/default", status: 1)
            )?.count,
            0
        )
        XCTAssertEqual(
            SessionService.parseDiscovery(
                probe("error connecting to /private/tmp/tmux-501/default (No such file or directory)", status: 1)
            )?.count,
            0
        )

        // Nobody answered. These must stay unknown.
        XCTAssertNil(SessionService.parseDiscovery(probe("ssh: connect to host devbox port 22: Operation timed out", status: 255)))
        XCTAssertNil(SessionService.parseDiscovery(probe("Permission denied (publickey).", status: 255)))
        XCTAssertNil(SessionService.parseDiscovery(probe("tetmux: tmux not found on remote host", status: 127)))
        XCTAssertNil(SessionService.parseDiscovery(probe("", status: -1)))
        // A block tmux refused is not a list of nothing either.
        XCTAssertNil(SessionService.parseDiscovery(probe("%begin 1 2 0\r\nno such thing\r\n%error 1 2 0\r\n")))
    }

    /// An ssh banner ahead of the answer is what the `%begin` framing is for — the reason discovery
    /// asks in control mode rather than reading plain `list-sessions` output.
    func testABannerAheadOfTheAnswerIsIgnored() {
        let output = """
        ##########################################\r
        # Authorised users only. All activity is #\r
        # monitored and reported.                #\r
        ##########################################\r
        %begin 1785940547 9452 0\r
        $2|0|work\r
        %end 1785940547 9452 0\r

        """
        let sessions = SessionService.parseDiscovery(
            CommandProbe.Result(status: 0, output: Data(output.utf8), timedOut: false)
        )
        XCTAssertEqual(sessions?.map(\.name), ["work"])
    }

    // MARK: - Passthrough (§4.6, F4.27)

    /// The fallback is the same invocation with `-CC` removed and nothing else changed.
    ///
    /// Worth pinning as an equality rather than an absence: passthrough dropping a flag it should
    /// have kept — `-u`, and a pane full of replacement characters — is the failure that looks like a
    /// font problem, and dropping `-2` is one that looks like a colour scheme.
    func testPassthroughIsControlModeWithoutTheControlFlag() {
        let passthrough = TmuxCommand.localPassthroughArguments(mode: .createOrAttach(sessionName: "work"))
        let control = TmuxCommand.localArguments(mode: .createOrAttach(sessionName: "work"))
        XCTAssertEqual(passthrough, ["-2", "-u", "new-session", "-A", "-s", "work", "-c", "#{HOME}"])
        XCTAssertEqual(passthrough, control.filter { $0 != "-CC" })
    }

    func testRemotePassthroughKeepsTheMissingTmuxCheck() {
        let command = TmuxCommand.remoteCommand(mode: .attach(sessionName: "work"), controlMode: false)
        XCTAssertTrue(command.contains("exec tmux -2 -u attach-session -t 'work'"), command)
        XCTAssertFalse(command.contains("-CC"), command)
        // R3.8's last row is reached through this message, in passthrough exactly as in control mode.
        XCTAssertTrue(command.contains("command -v tmux"), command)
    }

    /// R3.8's "tmux absent" row, which is the one connection failure with something better to offer
    /// than a retry — and which must not swallow the failures that are not it.
    func testAMissingTmuxIsToldFromEveryOtherFailure() {
        XCTAssertTrue(SessionService.describesMissingTmux("tetmux: tmux not found on remote host"))
        XCTAssertTrue(SessionService.describesMissingTmux("bash: tmux: command not found"))
        XCTAssertTrue(SessionService.describesMissingTmux("Executable not found on PATH: tmux"))

        XCTAssertFalse(SessionService.describesMissingTmux("Permission denied (publickey)."))
        XCTAssertFalse(SessionService.describesMissingTmux("ssh: connect to host devbox port 22: No route to host"))
        XCTAssertFalse(SessionService.describesMissingTmux("duplicate session: tmux-work"))
        XCTAssertFalse(SessionService.describesMissingTmux("Connection closed"))
    }

    /// The plain shell is the user's own, since that is what "a shell on this host" means — and it
    /// falls back to `/bin/sh` rather than to nothing when the environment does not say.
    func testThePlainShellIsALoginShell() {
        XCTAssertEqual(TmuxCommand.localShellInvocation(shell: "/bin/zsh").executable, "/bin/zsh")
        XCTAssertEqual(TmuxCommand.localShellInvocation(shell: "/bin/zsh").arguments, ["-l"])
        XCTAssertEqual(TmuxCommand.localShellInvocation(shell: nil).executable, "/bin/sh")
        XCTAssertEqual(TmuxCommand.localShellInvocation(shell: "").executable, "/bin/sh")
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

    // MARK: - The copyable attach command

    func testTheLocalAttachCommandIsWhatSomebodyWouldType() {
        let local = HostConfig(id: "local", name: "local", isLocal: true)
        XCTAssertEqual(
            TmuxCommand.attachCommandLine(host: local, sessionName: "work"),
            "tmux attach -t work"
        )
    }

    /// The whole point of the line is that it is *not* the invocation this app makes. A person
    /// pasting `tmux -CC` gets a screenful of protocol and a terminal they cannot type into.
    func testTheAttachCommandIsNeverControlMode() {
        let remote = HostConfig(id: "r", name: "devbox", hostname: "devbox.example.org")
        for command in [
            TmuxCommand.attachCommandLine(host: remote, sessionName: "work"),
            TmuxCommand.attachCommandLine(
                host: HostConfig(id: "l", name: "local", isLocal: true), sessionName: "work"
            ),
        ] {
            XCTAssertFalse(command.contains("-CC"))
            XCTAssertFalse(command.contains("%begin"))
        }
    }

    /// tmux refuses to attach without a tty, and ssh gives no tty when it is handed a command.
    func testTheRemoteAttachCommandForcesATty() {
        let remote = HostConfig(id: "r", name: "devbox", user: "ada")
        let command = TmuxCommand.attachCommandLine(host: remote, sessionName: "work")
        XCTAssertEqual(command, "ssh -t ada@devbox 'tmux attach -t work'")
    }

    func testTheAttachCommandCarriesANonDefaultPortAndTheUsersOwnOptions() {
        let remote = HostConfig(
            id: "r", name: "devbox", hostname: "devbox.example.org", port: 2222,
            extraSshArguments: "-o \"ProxyJump=bastion\""
        )
        XCTAssertEqual(
            TmuxCommand.attachCommandLine(host: remote, sessionName: "work"),
            "ssh -t -o \"ProxyJump=bastion\" -p 2222 devbox.example.org 'tmux attach -t work'"
        )
    }

    /// Port 22 is ssh's own default and `~/.ssh/config` may say otherwise — the same rule the real
    /// invocation follows.
    func testTheAttachCommandLeavesTheDefaultPortToSsh() {
        let remote = HostConfig(id: "r", name: "devbox", port: 22)
        XCTAssertFalse(TmuxCommand.attachCommandLine(host: remote, sessionName: "work").contains("-p"))
    }

    /// Forwards and X11 belong to tetmux's channel, not to reaching the host: the ports are already
    /// bound by the connection this app is holding open, so a pasted duplicate would fail.
    func testTheAttachCommandCarriesNothingBelongingToThisApplicationsChannel() {
        let remote = HostConfig(
            id: "r", name: "devbox",
            forwards: [PortForward(kind: .local, listenPort: 8080, destinationHost: "localhost", destinationPort: 80)],
            forwardsX11: true
        )
        let command = TmuxCommand.attachCommandLine(host: remote, sessionName: "work")
        XCTAssertFalse(command.contains("-L"))
        XCTAssertFalse(command.contains("-X"))
        XCTAssertFalse(command.contains("ControlMaster"), "that socket is this application's")
    }

    /// A wrapper replaces ssh entirely, so describing that host with an ssh line would describe a
    /// route nobody takes. It takes the remote command last, exactly as `invocation` hands it one.
    func testAWrappedHostIsDescribedByItsOwnWrapper() {
        let wrapped = HostConfig(id: "w", name: "container", customCommand: "docker exec -it dev sh -c")
        XCTAssertEqual(
            TmuxCommand.attachCommandLine(host: wrapped, sessionName: "work"),
            "docker exec -it dev sh -c 'tmux attach -t work'"
        )
    }

    /// A session name is user data here as everywhere else, and this line ends up in a shell.
    func testASessionNameIsQuotedWhenItNeedsToBe() {
        let local = HostConfig(id: "local", name: "local", isLocal: true)
        XCTAssertEqual(
            TmuxCommand.attachCommandLine(host: local, sessionName: "my session"),
            "tmux attach -t 'my session'"
        )
        XCTAssertEqual(
            TmuxCommand.attachCommandLine(host: local, sessionName: "$(id)"),
            "tmux attach -t '$(id)'"
        )
        // Both layers: the remote shell parses the name, and the local one parses the whole word.
        let remote = HostConfig(id: "r", name: "devbox")
        XCTAssertEqual(
            TmuxCommand.attachCommandLine(host: remote, sessionName: "my session"),
            #"ssh -t devbox 'tmux attach -t '\''my session'\'''"#
        )
    }

    /// Quoting a word that did not need it is what makes a copied command read like machine output.
    /// The exceptions are the ones a shell would expand at the *start* of a word.
    func testAnOrdinaryWordIsLeftUnquotedAndAnExpandableOneIsNot() {
        for plain in ["work", "build-2", "a_b.c", "user@host", "/tmp/x", "1:2"] {
            XCTAssertEqual(TmuxCommand.shellWord(plain), plain)
        }
        for quoted in ["", "a b", "~work", "=work", "a'b", "a;b", "$x", "a*b", "a\nb"] {
            XCTAssertTrue(
                TmuxCommand.shellWord(quoted).hasPrefix("'"),
                "\(quoted) must not reach a shell as a bare word"
            )
        }
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

// MARK: - Session naming

/// One rule for what tetmux calls a session it made, in the layer both callers reach.
///
/// There were two. The sidebar's New Session counted up `tetmux_N`, while anything the *connection*
/// created — a first connect, or an empty server the user asked to open — used the constant
/// `tetmux-main`, from a function that took a `HostConfig` and ignored it. F4.15's placeholder is
/// where that showed: "Recreate “tetmux-main”" beside a second button that also made `tetmux-main`,
/// so two different-sounding choices did the same thing.
final class SessionNamingTests: XCTestCase {

    func testStartsAtOne() {
        XCTAssertEqual(SessionNaming.nextName(taken: []), "tetmux_1")
    }

    /// tmux refuses a duplicate session name, and that refusal would surface as a failure banner for
    /// a command the user never typed a name for.
    func testSkipsNamesAlreadyTaken() {
        XCTAssertEqual(SessionNaming.nextName(taken: ["tetmux_1", "tetmux_2"]), "tetmux_3")
    }

    /// The lowest free index, not a running count: closing one in the middle gives its name back
    /// rather than leaving a gap and climbing forever.
    func testReusesAFreedIndex() {
        XCTAssertEqual(SessionNaming.nextName(taken: ["tetmux_1", "tetmux_3"]), "tetmux_2")
    }

    func testIgnoresUnrelatedNames() {
        XCTAssertEqual(SessionNaming.nextName(taken: ["work", "tetmux-main", "notes"]), "tetmux_1")
    }
}

/// "The server has nothing on it" and "I cannot reach this host" are one `ConnectionState` and
/// completely different news — the same shape as F4.15's ended-session versus dropped-link split.
final class EmptyServerTests: XCTestCase {

    private func host(
        state: ConnectionState, ended: String?, sessions: [TmuxSession] = []
    ) -> HostState {
        var host = HostState(
            config: HostConfig(id: "local", name: "local", isLocal: true),
            connectionState: state,
            sessions: sessions
        )
        host.endedSessionName = ended
        return host
    }

    /// The state the local host lands in when its last session goes: reachable, with nothing on it.
    func testAnEndedSessionWithNothingLeftIsAnEmptyServer() {
        XCTAssertTrue(host(state: .disconnected, ended: "work").serverIsEmpty)
    }

    /// A host that has never been connected has an empty session list too, and about that host we
    /// genuinely do not know — which is why the remembered name is what answers this and not the
    /// list. Labelling it "no sessions" would be a claim nothing supports.
    func testAHostThatWasNeverConnectedIsNotAnEmptyServer() {
        XCTAssertFalse(host(state: .disconnected, ended: nil).serverIsEmpty)
    }

    /// A dropped link leaves the sessions listed and out of reach, not gone.
    func testADroppedLinkIsNotAnEmptyServer() {
        let live = [TmuxSession(id: "$1", name: "work", windows: [])]
        XCTAssertFalse(host(state: .disconnected, ended: "work", sessions: live).serverIsEmpty)
    }

    /// Only ever a reading of `.disconnected`. A connected host with no sessions yet is a different
    /// sentence and the sidebar already has one for it.
    func testOnlyADisconnectedHostCanBeAnEmptyServer() {
        XCTAssertFalse(host(state: .connected, ended: "work").serverIsEmpty)
        XCTAssertFalse(host(state: .connecting, ended: "work").serverIsEmpty)
    }
}
