import Foundation

/// Consumes screen's `ESC k <name> ST` window-title sequence out of a pane's byte stream.
///
/// **`%output` is what the program wrote, not what tmux drew.** Everything else in the app leans on
/// that — it is why 24-bit colour works with no code — but it cuts the other way for the sequences
/// tmux would have *eaten*. `TERM` inside a pane is `screen*`, so a shell that dresses its prompt up
/// with a window title takes the screen branch of the usual `case $TERM in` and emits `ESC k … ESC \`
/// rather than xterm's `OSC 0 ; … BEL`. tmux consumes that sequence (it is how a program renames a
/// window), a control-mode client is handed it verbatim, and SwiftTerm has no case for it: `ESC k`
/// dispatches as an unknown escape and returns the parser to *ground*, so the name that follows is
/// printed into the grid as ordinary text.
///
/// What that looks like is the bug it was found as: a prompt appearing twice, once in plain text and
/// once with its real styling, on one host and not another. The plain copy is the window title —
/// `juesteba@cwe-513-vml377:~` — and the styled one is the prompt it was named after. Only hosts
/// whose shell takes the `screen*` branch show it, which is what makes it look like tetmux misbehaving
/// on particular machines.
///
/// The name is **dropped rather than applied**. tmux owns window names: it parses this same sequence
/// for itself, and if `allow-rename` is on the rename arrives as `%window-renamed`, which is the one
/// path the tab strip listens to. Setting a title here as well would give a tab two sources that
/// disagree whenever `allow-rename` is off — which is the default.
///
/// Stateful because a chunk boundary can fall anywhere: the `%output` a sequence arrives in is
/// whatever tmux flushed, and P6.4's coalescing re-cuts it again. An `ESC` at the end of a buffer is
/// therefore *held* rather than emitted, which is exactly what the emulator's own parser does with
/// one — it would sit in its escape state waiting for the next byte either way.
public struct ScreenTitleFilter: Sendable {

    /// How much of an unterminated title to swallow before deciding there was no title.
    ///
    /// A missing `ST` must not cost the pane every byte it ever produces again. tmux caps its own
    /// string states for the same reason; the difference here is that overflow *resumes output*
    /// rather than staying silent, because a pane that has gone permanently blank is a far worse
    /// failure than a kilobyte of garbage that a repaint will clear anyway.
    public static let maximumTitleBytes = 1024

    private static let escape = UInt8(0x1b)
    private static let bell = UInt8(0x07)
    private static let k = UInt8(ascii: "k")
    private static let backslash = UInt8(ascii: "\\")

    private enum State: Sendable {
        /// Ordinary bytes, passed through.
        case ground
        /// An `ESC` has been seen and withheld; the next byte decides whether it was ours.
        case escape
        /// Inside `ESC k`, dropping bytes until the terminator.
        case title
        /// Inside a title, on an `ESC` that may be the `ST` that ends it.
        case titleEscape
    }

    private var state: State = .ground
    private var titleBytes = 0

    public init() {}

    /// Returns `bytes` with any screen title sequence removed, carrying partial state to the next call.
    public mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
        // The overwhelmingly common case, and the one P6.3 measures: no escape byte at all and no
        // sequence in flight, so there is nothing to copy and the array is handed straight back.
        if state == .ground, !bytes.contains(Self.escape) { return bytes }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = bytes.startIndex

        while index < bytes.endIndex {
            switch state {
            case .ground:
                // Copied a run at a time rather than a byte at a time: this sits on every pane's
                // paint path, and a per-byte loop here would add a second pass of the emulator's own
                // parsing cost to output that has nothing to do with titles.
                guard let next = bytes[index...].firstIndex(of: Self.escape) else {
                    output.append(contentsOf: bytes[index...])
                    index = bytes.endIndex
                    break
                }
                output.append(contentsOf: bytes[index..<next])
                index = bytes.index(after: next)
                state = .escape

            case .escape:
                let byte = bytes[index]
                if byte == Self.k {
                    state = .title
                    titleBytes = 0
                    index = bytes.index(after: index)
                } else if byte == Self.escape {
                    // `ESC ESC`: the first one was not ours after all, and the second is still undecided.
                    output.append(Self.escape)
                    index = bytes.index(after: index)
                } else {
                    // Somebody else's sequence. The withheld `ESC` goes out in front of it, in order.
                    output.append(Self.escape)
                    state = .ground
                }

            case .title:
                // Never scanned past what is left of the budget, so a stream with no terminator in
                // it at all cannot swallow a whole chunk before the cap is noticed.
                let allowance = Self.maximumTitleBytes - titleBytes
                let limit = bytes.index(index, offsetBy: allowance, limitedBy: bytes.endIndex)
                    ?? bytes.endIndex
                guard let next = bytes[index..<limit].firstIndex(where: {
                    $0 == Self.bell || $0 == Self.escape
                }) else {
                    titleBytes += bytes.distance(from: index, to: limit)
                    index = limit
                    if titleBytes >= Self.maximumTitleBytes { state = .ground }
                    break
                }
                titleBytes += bytes.distance(from: index, to: next)
                let terminator = bytes[next]
                index = bytes.index(after: next)
                // BEL ends it the way it ends an OSC — screen accepts both, and a prompt written by
                // hand is as likely to use one as the other.
                state = terminator == Self.bell ? .ground : .titleEscape

            case .titleEscape:
                let byte = bytes[index]
                index = bytes.index(after: index)
                if byte == Self.backslash {
                    state = .ground          // `ESC \` — the ST that closes the title.
                } else if byte != Self.escape {
                    titleBytes += 2
                    state = titleBytes >= Self.maximumTitleBytes ? .ground : .title
                }
                // An `ESC` here leaves us waiting on the next byte for the same reason as above.
            }
        }
        return output
    }
}
