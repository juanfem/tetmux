import Foundation

/// How a container arranges its children. Named after what the user sees, because tmux's
/// `{}` / `[]` and the words "horizontal"/"vertical" mean opposite things depending on whether
/// you are describing the divider or the arrangement.
public enum SplitDirection: Equatable, Sendable {
    /// tmux `{...}` — children sit side by side, divided by vertical lines.
    case leftRight
    /// tmux `[...]` — children are stacked, divided by horizontal lines.
    case topBottom
}

public indirect enum LayoutNode: Equatable, Sendable {
    case leaf(paneId: String, width: Int, height: Int, x: Int, y: Int)
    case container(direction: SplitDirection, width: Int, height: Int, x: Int, y: Int, children: [LayoutNode])

    /// Pane ids in left-to-right, top-to-bottom order, carrying the `%` sigil.
    public var paneIds: [String] {
        switch self {
        case .leaf(let paneId, _, _, _, _):
            return [paneId]
        case .container(_, _, _, _, _, let children):
            return children.flatMap(\.paneIds)
        }
    }

    public var width: Int {
        switch self {
        case .leaf(_, let w, _, _, _), .container(_, let w, _, _, _, _): return w
        }
    }

    public var height: Int {
        switch self {
        case .leaf(_, _, let h, _, _), .container(_, _, let h, _, _, _): return h
        }
    }

    public var x: Int {
        switch self {
        case .leaf(_, _, _, let x, _), .container(_, _, _, let x, _, _): return x
        }
    }

    public var y: Int {
        switch self {
        case .leaf(_, _, _, _, let y), .container(_, _, _, _, let y, _): return y
        }
    }

    /// Cell size of a specific pane, for forcing the emulator to the size tmux decided (§3.3).
    public func cellSize(ofPane paneId: String) -> (cols: Int, rows: Int)? {
        switch self {
        case .leaf(let id, let w, let h, _, _):
            return id == paneId ? (w, h) : nil
        case .container(_, _, _, _, _, let children):
            for child in children {
                if let found = child.cellSize(ofPane: paneId) { return found }
            }
            return nil
        }
    }
}

public enum LayoutParseError: Error, Equatable {
    case empty
    case checksumMismatch(expected: UInt16, actual: UInt16)
    case syntaxError(reason: String)
}

public enum LayoutParser {
    /// tmux's `layout_checksum` from layout-custom.c.
    public static func computeChecksum(_ layout: String) -> UInt16 {
        var csum: UInt16 = 0
        for byte in layout.utf8 {
            csum = (csum >> 1) &+ ((csum & 1) << 15)
            csum = csum &+ UInt16(byte)
        }
        return csum
    }

    /// Parses `bc62,80x24,0,0{40x24,0,0,1,39x24,41,0,2}` into a typed tree (R3.5).
    ///
    /// - Parameter verifyChecksum: when true, a body that does not match its `bc62,` prefix is
    ///   rejected rather than parsed. Off by default so a checksum quirk in some tmux build can
    ///   never cost the user their panes; the geometry test suite turns it on.
    public static func parse(_ input: String, verifyChecksum: Bool = false) throws -> LayoutNode {
        var body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw LayoutParseError.empty }

        // Optional four-hex-digit checksum prefix.
        if body.count > 5 {
            let prefix = String(body.prefix(4))
            let afterPrefix = body.index(body.startIndex, offsetBy: 4)
            if body[afterPrefix] == ",",
               prefix.allSatisfy(\.isHexDigit),
               let expected = UInt16(prefix, radix: 16) {
                let remainder = String(body[body.index(after: afterPrefix)...])
                let actual = computeChecksum(remainder)
                if verifyChecksum && expected != actual {
                    throw LayoutParseError.checksumMismatch(expected: expected, actual: actual)
                }
                body = remainder
            }
        }

        var scanner = Scanner(Array(body.utf8))
        let node = try parseNode(&scanner, depth: 0)
        guard scanner.isAtEnd else {
            throw LayoutParseError.syntaxError(reason: "trailing input at offset \(scanner.offset)")
        }
        return node
    }

    // MARK: - Recursive descent

    /// How deep a layout may nest before it is rejected.
    ///
    /// A stack overflow is not catchable either, and the codec accepts a line up to 16 MB — enough
    /// nested `{` to run the stack out long before anything else complains. Real layouts are a
    /// handful deep: this is far beyond any window a person has ever split by hand, and it bounds the
    /// recursion.
    private static let maxDepth = 64

    private static func parseNode(_ s: inout Scanner, depth: Int) throws -> LayoutNode {
        guard depth <= maxDepth else {
            throw LayoutParseError.syntaxError(reason: "nested deeper than \(maxDepth) at offset \(s.offset)")
        }
        let width = try s.readInt(terminator: UInt8(ascii: "x"))
        let height = try s.readInt(terminator: UInt8(ascii: ","))
        let x = try s.readInt(terminator: UInt8(ascii: ","))
        let y = try s.readInt()

        switch s.peek() {
        case UInt8(ascii: ","):
            s.advance()
            let paneNumber = try s.readInt()
            return .leaf(paneId: "%\(paneNumber)", width: width, height: height, x: x, y: y)

        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let open = s.peek()!
            let direction: SplitDirection = open == UInt8(ascii: "{") ? .leftRight : .topBottom
            let close: UInt8 = open == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
            s.advance()

            var children: [LayoutNode] = []
            var closed = false
            while !s.isAtEnd {
                children.append(try parseNode(&s, depth: depth + 1))
                guard let next = s.peek() else { break }
                if next == UInt8(ascii: ",") {
                    s.advance()
                } else if next == close {
                    s.advance()
                    closed = true
                    break
                } else {
                    // Neither a separator nor our terminator: bail rather than spin forever.
                    throw LayoutParseError.syntaxError(
                        reason: "unexpected '\(Character(UnicodeScalar(next)))' at offset \(s.offset)"
                    )
                }
            }
            guard closed else {
                throw LayoutParseError.syntaxError(reason: "unterminated container at offset \(s.offset)")
            }
            guard !children.isEmpty else {
                throw LayoutParseError.syntaxError(reason: "empty container at offset \(s.offset)")
            }
            return .container(direction: direction, width: width, height: height, x: x, y: y, children: children)

        default:
            throw LayoutParseError.syntaxError(reason: "expected pane id or container at offset \(s.offset)")
        }
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private(set) var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset >= bytes.count }

        func peek() -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

        mutating func advance() { offset += 1 }

        /// Reads digits, then requires `terminator` and consumes it.
        mutating func readInt(terminator: UInt8) throws -> Int {
            let value = try readInt()
            guard peek() == terminator else {
                throw LayoutParseError.syntaxError(
                    reason: "expected '\(Character(UnicodeScalar(terminator)))' at offset \(offset)"
                )
            }
            advance()
            return value
        }

        /// Reads a run of digits, stopping at the first non-digit.
        ///
        /// Overflow is a thrown error rather than an arithmetic trap. Swift traps on `*` and `+`
        /// overflow, and a trap is not catchable — so `try? LayoutParser.parse` at the call sites
        /// would not have contained it, and a `%layout-change` garbled on the wire took the whole app
        /// down. Nothing here is ever legitimately large: these are cells and offsets.
        mutating func readInt() throws -> Int {
            let start = offset
            var value = 0
            while offset < bytes.count, bytes[offset] >= 48, bytes[offset] <= 57 {
                let (multiplied, overflowedMultiply) = value.multipliedReportingOverflow(by: 10)
                guard !overflowedMultiply else {
                    throw LayoutParseError.syntaxError(reason: "number too large at offset \(start)")
                }
                let (added, overflowedAdd) = multiplied.addingReportingOverflow(Int(bytes[offset] - 48))
                guard !overflowedAdd else {
                    throw LayoutParseError.syntaxError(reason: "number too large at offset \(start)")
                }
                value = added
                offset += 1
            }
            guard offset > start else {
                throw LayoutParseError.syntaxError(reason: "expected a number at offset \(offset)")
            }
            return value
        }
    }
}
