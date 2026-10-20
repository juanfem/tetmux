import Foundation

/// What is typed between asking for a new tab and the tab existing.
///
/// Control mode answers `new-window` with no id, so the tab is not selectable until the topology
/// refresh brings it back (`AppModel.RevealRequest`) — and before the command is even sent there is a
/// `display-message` round trip for its start directory. For all of that the old tab is still the
/// selected one and its pane is still first responder, so ⌘T followed at once by typing put the
/// first keystrokes into the tab being left. Reported as *"if I type too early the keyboard stays on
/// the previous tab"*; on a remote host the gap is two round trips long and easily reached.
///
/// So the window holds what the user types for as long as a new tab is on its way, and hands it to
/// the tab that gets selected next (`AppModel.select`), which is the new one unless the user went
/// somewhere else in the meantime — in which case that is where they were typing.
///
/// Three things about it are load-bearing.
///
/// **Only the user's input is held.** A pane's answers to its program's queries (`CSI 6n`, OSC 11)
/// belong to the pane that was asked, and holding them would leave a background program waiting on a
/// reply that arrives in somebody else's shell. `ComposingTerminalView.isAnsweringQuery` is what
/// tells the two apart, as it is for focus.
///
/// **Only what is aimed at the focused pane is held.** Typing and ⌘V are; a drop, a middle-click and
/// the context menu's Paste name their pane with the pointer, and go to it.
///
/// **A hold that is never released drops what it held.** A `new-window` tmux refused has no tab to
/// deliver to, and replaying the bytes into the old pane after the user had moved on from it is
/// typing a command somewhere they did not mean. The expiry is the same 15 s every pending creation
/// gets.
@MainActor
public final class NewTabInputHold {
    /// Kept apart because they leave differently: keys as `send-keys`, a paste through a tmux buffer.
    public enum Input: Equatable {
        case keys([UInt8])
        case paste(String)
    }

    public private(set) var isHolding = false
    private var held: [Input] = []
    /// Bumped on every begin and end, so an expiry scheduled by an earlier hold ends nothing.
    private var generation = 0
    private let timeout: Duration

    public init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
    }

    /// Not clearing what is held: a second ⌘T before the first tab arrives must not drop what was
    /// typed after the first, which still goes to whichever tab is selected next.
    func begin() {
        isHolding = true
        generation += 1
        let started = generation
        Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard let self, self.generation == started else { return }
            self.end()
        }
    }

    /// Whether `input` was taken. False means no tab is on its way and it goes where it was going.
    func hold(_ input: Input) -> Bool {
        guard isHolding else { return false }
        held.append(input)
        return true
    }

    /// Stops holding and returns what was typed meanwhile, in order.
    @discardableResult
    func end() -> [Input] {
        isHolding = false
        generation += 1
        defer { held = [] }
        return held
    }
}
