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

    // MARK: - Local invocation

    func testLocalArgumentsRequestControlMode() {
        let args = TmuxCommand.localArguments(sessionName: "work", attachOnly: false)
        XCTAssertEqual(Array(args[0..<3]), ["-CC", "-2", "-u"])
        XCTAssertEqual(args, ["-CC", "-2", "-u", "new-session", "-A", "-s", "work"])
    }

    func testLocalAttachOnlyDoesNotCreate() {
        // F4.15: reconnection must never create a session.
        let args = TmuxCommand.localArguments(sessionName: "work", attachOnly: true)
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
            remoteCommand: TmuxCommand.remoteCommand(sessionName: "work", attachOnly: false)
        )
        guard let separator = args.firstIndex(of: "--") else { return XCTFail("expected a -- separator") }
        XCTAssertEqual(
            args.count - separator - 1, 1,
            "everything after -- must be a single argument; ssh concatenates the rest"
        )
        XCTAssertEqual(args[separator - 1], "devbox", "the destination must precede --")
    }

    func testRemoteCommandLaunchesTmuxInControlMode() {
        let command = TmuxCommand.remoteCommand(sessionName: "work", attachOnly: false)
        XCTAssertTrue(command.contains("exec tmux -CC -2 -u new-session -A -s 'work'"), command)
        XCTAssertTrue(command.contains("command -v tmux"), "a missing remote tmux must say so")
        XCTAssertTrue(command.contains("/opt/homebrew/bin"), "non-interactive shells miss Homebrew")
    }

    func testRemoteSessionNameIsQuoted() {
        let command = TmuxCommand.remoteCommand(sessionName: "my project", attachOnly: true)
        XCTAssertTrue(command.contains("attach-session -t 'my project'"), command)
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

        window.apply(layoutString: "5967,80x24,0,0,20")

        XCTAssertEqual(window.panes.map(\.id), ["%20"])
        XCTAssertEqual(window.activePaneId, "%20", "focus must move off the pane that went away")
    }

    func testUnparseableLayoutLeavesTheWindowUsable() {
        var window = TmuxWindow(id: "@1", name: "zsh", activePaneId: "%5")
        window.apply(layoutString: "not a layout")
        XCTAssertNil(window.layoutTree)
        XCTAssertEqual(window.preferredPaneId, "%5", "the surface still has a pane to bind to")
    }
}
