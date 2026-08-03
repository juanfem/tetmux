import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// `AppModel` decisions that need no channel and no AppKit. Everything here was previously
/// unreachable from the test bundle, which linked only `tetmuxCore`.
@MainActor
final class AppModelTests: XCTestCase {

    private func window(_ id: String, name: String = "shell", panes: [String] = ["%1"]) -> TmuxWindow {
        var window = TmuxWindow(id: id, name: name)
        window.panes = panes.map { TmuxPane(id: $0, command: "vim") }
        return window
    }

    private func host(id: String = "local", sessions: [TmuxSession]) -> HostState {
        HostState(
            config: HostConfig(id: id, name: id, isLocal: true),
            connectionState: .connected,
            sessions: sessions,
            activeSessionId: sessions.first?.id
        )
    }

    // MARK: - Closing a window (F4.9)

    /// A window linked to several sessions can simply leave this one, so closing it asks nothing:
    /// nothing is destroyed and there is nothing to confirm.
    func testClosingAMultiLinkedWindowNeedsNoConfirmation() {
        let shared = window("@5")
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [shared], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [shared]),
        ])]

        XCTAssertNil(
            model.closeWindow(hostId: "local", window: shared),
            "an unlinkable window must not raise a destructive confirmation"
        )
        XCTAssertNil(model.pendingClose)
    }

    /// A window in exactly one session cannot be removed without destroying it — tmux refuses the
    /// unlink outright — so this is the one case that stops and asks (F4.10).
    func testClosingASingleLinkedWindowAsksBeforeKilling() {
        let only = window("@7", name: "build", panes: ["%1", "%2"])
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [only], isAttached: true),
        ])]

        let pending = model.closeWindow(hostId: "local", window: only)
        let confirmation = try? XCTUnwrap(pending)
        XCTAssertEqual(confirmation?.windowId, "@7")
        XCTAssertEqual(confirmation?.windowName, "build")
        XCTAssertEqual(confirmation?.paneCount, 2)
        // F4.10 — the confirmation has to name what is running, not just the window.
        XCTAssertEqual(confirmation?.runningCommands, ["vim", "vim"])
    }

    /// A window belonging to a host we know nothing about is not silently unlinked. Treating an
    /// unknown host as "not multi-linked" is the safe direction: it asks rather than acting.
    func testClosingAWindowOnAnUnknownHostAsks() {
        let model = AppModel()
        model.hosts = []
        XCTAssertNotNil(model.closeWindow(hostId: "nope", window: window("@1")))
    }

    // MARK: - Scope resolution

    /// Menu commands act on the frontmost window, which is the torn-off one when it has focus. This
    /// is what makes ⌘T open a window in *that* window's session rather than the sidebar's.
    func testActiveScopePrefersTheFrontmostWindow() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1")], isAttached: true),
        ])]
        model.selectedHostId = "local"
        model.selectedSessionId = "$1"
        model.selectedWindowId = "@1"

        XCTAssertEqual(model.activeScope.windowId, "@1")

        model.frontmostScope = AppModel.Scope(
            hostId: "local", sessionId: "$9", windowId: "@42", paneId: "%42"
        )
        XCTAssertEqual(model.activeScope.windowId, "@42")
        XCTAssertEqual(model.activeScope.paneId, "%42")

        // The main window taking focus again clears it and the sidebar selection is the subject.
        model.frontmostScope = nil
        XCTAssertEqual(model.activeScope.windowId, "@1")
    }

    // MARK: - Keymap policy (F4.19/F4.22)

    /// The whole default set lives in Cmd space so that bare Ctrl chords — readline, Emacs, tmux's
    /// own prefix — reach the pane untouched.
    func testEveryDefaultBindingUsesCommand() {
        let keymap = KeymapPolicy.default
        for shortcut in ApplicationShortcut.allCases {
            guard let binding = keymap.binding(for: shortcut) else { continue }
            XCTAssertTrue(
                binding.modifiers.contains(.command),
                "\(shortcut) is bound without Cmd, so it would intercept a chord meant for the pane"
            )
        }
    }

    func testShortcutMatchingIsExactAboutModifiers() {
        let keymap = KeymapPolicy.default
        XCTAssertEqual(keymap.shortcut(for: keyEvent("d", [.command])), .splitRight)
        XCTAssertEqual(keymap.shortcut(for: keyEvent("d", [.command, .shift])), .splitDown)
        // Bare Ctrl chords are the pane's (F4.20) — Ctrl+K is kill-line, not the launcher.
        XCTAssertNil(keymap.shortcut(for: keyEvent("k", [.control])))
        XCTAssertNil(keymap.shortcut(for: keyEvent("k", [])))
    }

    /// F4.21 — after the literal escape, even a bound chord belongs to the pane.
    func testLiteralEscapeLetsABoundChordThrough() {
        let keymap = KeymapPolicy.default
        XCTAssertEqual(keymap.shortcut(for: keyEvent("v", [.command])), .paste)
        XCTAssertNil(keymap.shortcut(for: keyEvent("v", [.command]), literalEscapeActive: true))
    }

    private func keyEvent(_ character: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!
    }
}
