import XCTest
@testable import tetmuxCore

/// Screen's `ESC k <name> ST`, which arrives in `%output` because tmux passes a pane's own bytes
/// through and which SwiftTerm prints as text — the plain-looking second copy of a prompt.
///
/// The cases that matter are the boundaries, because the sequence is not delivered as a unit:
/// `%output` is cut wherever tmux flushed and P6.4 re-cuts it per display frame, so every byte of it
/// is a place a chunk can end. A filter that only works on whole sequences would pass a test written
/// with one string literal and fail on the wire.
final class ScreenTitleFilterTests: XCTestCase {

    private func filtered(_ chunks: [String]) -> String {
        var filter = ScreenTitleFilter()
        var output: [UInt8] = []
        for chunk in chunks {
            output.append(contentsOf: filter.filter(Array(chunk.utf8)))
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The bug as it was reported, in the bytes it was reported in.
    ///
    /// Captured from a real host: bash on `TERM=screen-256color` names the window after the prompt,
    /// so the discarded title is a plain-text copy of the styled prompt that follows it — which is
    /// what "the prompt is duplicated, once without colour" is.
    func testTheTitleThatLooksLikeASecondPromptIsRemoved() {
        let title = "\u{1b}kjuesteba@cwe-513-vml377:~\u{1b}\\"
        let prompt = "\u{1b}[?2004h\u{1b}[42;01;37mjuesteba@cwe-513-vml377\u{1b}[00m ~ $ "

        XCTAssertEqual(
            filtered([title + prompt]), prompt,
            "the window title is still in the stream; it would be printed as a plain copy of the prompt"
        )
    }

    /// Screen accepts BEL as well as ST, and a prompt written by hand is as likely to use it.
    func testABellTerminatesTheTitleToo() {
        XCTAssertEqual(filtered(["\u{1b}khost:~\u{07}$ "]), "$ ")
    }

    /// The property the state machine exists for: the same stream cut in every possible place.
    func testTheSequenceSurvivesBeingSplitAtEveryByte() {
        let stream = "a\u{1b}kname\u{1b}\\b"
        let bytes = Array(stream.utf8)
        for split in 0...bytes.count {
            var filter = ScreenTitleFilter()
            var output = filter.filter(Array(bytes[0..<split]))
            output.append(contentsOf: filter.filter(Array(bytes[split...])))
            XCTAssertEqual(
                String(decoding: output, as: UTF8.self), "ab",
                "split after \(split) byte(s) did not produce the same result as an unsplit stream"
            )
        }
    }

    /// Everything that is not this sequence goes through untouched — including the escapes that look
    /// most like it. An `OSC 0` title is the xterm spelling of the very same thing and SwiftTerm
    /// *does* implement it, so eating it here would swap one bug for a subtler one.
    func testOtherEscapeSequencesAreUntouched() {
        let stream = "\u{1b}[38;2;17;183;201mX\u{1b}[0m\u{1b}]0;juan@jymtp ~\u{07}\u{1b}[?2004h$ "
        XCTAssertEqual(filtered([stream]), stream)
    }

    /// An `ESC` at the end of a chunk is withheld, not dropped: it is emitted as soon as the next
    /// byte says it was not ours. The emulator's own parser waits in exactly the same way, so
    /// nothing is delayed that was not already.
    func testAWithheldEscapeIsEmittedOnceItIsNotOurs() {
        XCTAssertEqual(filtered(["x\u{1b}", "[0mY"]), "x\u{1b}[0mY")
        // And a doubled ESC does not swallow the first one.
        XCTAssertEqual(filtered(["\u{1b}\u{1b}[0m"]), "\u{1b}\u{1b}[0m")
    }

    /// A pane must not go permanently blank because one sequence was never terminated. Overflow
    /// gives up on the title and resumes output; the cost is bounded and a repaint clears it.
    func testAnUnterminatedTitleGivesUpInsteadOfEatingThePane() {
        let runaway = String(repeating: "x", count: ScreenTitleFilter.maximumTitleBytes + 1)
        let output = filtered(["\u{1b}k" + runaway + "back"])

        XCTAssertFalse(output.isEmpty, "the pane would produce nothing ever again")
        XCTAssertTrue(
            output.hasSuffix("back"),
            "output did not resume after the cap: \(output.suffix(16).debugDescription)"
        )
    }

    /// The fast path has to be a *path*, not a different implementation: a chunk with no escape in
    /// it comes back as it went in, and one arriving mid-title is still filtered.
    func testAChunkWithNoEscapeIsPassedThrough() {
        XCTAssertEqual(filtered(["plain text\r\n"]), "plain text\r\n")
        XCTAssertEqual(filtered(["\u{1b}k", "still the title", "\u{1b}\\done"]), "done")
    }
}
