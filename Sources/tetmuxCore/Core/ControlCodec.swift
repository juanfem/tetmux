import Foundation

/// Parses a tmux control-mode byte stream into `ControlEvent`s.
///
/// Pure value type (R3.1): no I/O, no processes, no timers, no `async`. Everything it does is
/// driven by `feed(_:)`, so the whole protocol layer is testable against recorded fixtures with
/// nothing running.
public struct ControlCodec: Sendable {
    /// Unconsumed bytes. `scanned` is how far into `buffer` we have already looked for a newline,
    /// so a partial line arriving in many chunks is not re-scanned from the start each time.
    private var buffer: [UInt8] = []
    private var scanned: Int = 0
    private var activeCommandNumber: Int?
    private var sawFirstBegin = false

    /// Lines longer than this are truncated rather than buffered forever. tmux never emits
    /// anything close to it; a runaway line means we are reading something that is not tmux.
    private static let maxLineLength = 16 * 1024 * 1024

    public init() {}

    /// Whether a `%begin`'s flags say the block answers a command **this** client sent.
    ///
    /// Correlation is by order against a FIFO of pending commands, which works only for as long as
    /// every block on the wire is one of ours. Not every block is. tmux opens a block of its own on
    /// attach, before we can write anything — that one has always been special-cased — and it opens
    /// one for **every command a keystroke dispatches through a pane's mode table**. Verified on
    /// 3.7b: with a pane in copy mode, `send-keys -t %0 Up` produces the response to `send-keys`
    /// (flags `1`) *and then* a second, unsolicited block (flags `0`) for the `cursor-up` the key was
    /// bound to. Three `Up`s produce three of them. Consuming those from the FIFO misattributes every
    /// response afterwards for the life of the channel, and it needs no copy-mode feature to happen:
    /// a `prefix [` typed into a pane, or another client entering the mode, is enough.
    ///
    /// Bit 0, not equality, because the field is a bitfield and tmux is entitled to add flags. An
    /// **absent** field is read as ours: every version in the R3.6 matrix (3.0 through 3.5) and 3.7b
    /// emits it, so its absence would mean a tmux this was never verified against, and the old
    /// behaviour is the safer guess there — treating everything as unsolicited would answer no
    /// command at all.
    public static func blockAnswersOurCommand(flags: String) -> Bool {
        guard !flags.isEmpty else { return true }
        guard let value = Int(flags) else { return true }
        return value & 1 == 1
    }

    public mutating func feed(_ incoming: some Sequence<UInt8>) -> [ControlEvent] {
        buffer.append(contentsOf: incoming)
        var events: [ControlEvent] = []

        var lineStart = 0
        var i = scanned
        while i < buffer.count {
            guard buffer[i] == UInt8(ascii: "\n") else {
                i += 1
                continue
            }
            var lineEnd = i
            // tmux's pty is in the default (ONLCR) mode, so lines arrive CRLF-terminated.
            if lineEnd > lineStart && buffer[lineEnd - 1] == UInt8(ascii: "\r") {
                lineEnd -= 1
            }
            if let event = parseLine(Array(buffer[lineStart..<lineEnd])) {
                events.append(event)
            }
            i += 1
            lineStart = i
        }

        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }
        scanned = buffer.count

        if buffer.count > Self.maxLineLength {
            buffer.removeAll(keepingCapacity: false)
            scanned = 0
        }

        return events
    }

    // MARK: - Line dispatch

    private mutating func parseLine(_ raw: [UInt8]) -> ControlEvent? {
        var bytes = raw

        // The very first thing tmux -CC writes is a DCS introducer (ESC P 1000 p) glued to the
        // first `%begin`. Over ssh there may also be a banner or shell noise ahead of it. Anything
        // before the first `%begin` is not protocol, so skip to it.
        if !sawFirstBegin {
            if let beginIndex = Self.find(Array("%begin ".utf8), in: bytes) {
                bytes.removeFirst(beginIndex)
            } else if !bytes.isEmpty && bytes[0] != UInt8(ascii: "%") {
                return nil
            }
        }

        // Framing outranks dispatch. Inside a `%begin` block every line is response content — even
        // one starting with `%` — and the only thing that ends the block is tmux's own `%end`/`%error`
        // carrying the number the `%begin` opened with.
        //
        // Verified on 3.7b under a pty, with a pane emitting continuously while commands with large
        // responses were issued: `%output` never appears between a `%begin` and its `%end`. tmux
        // writes a block as a unit, so anything that looks like a notification in there came from the
        // command's own output and is not protocol.
        //
        // Dispatching first was silent corruption in both directions. Result lines starting with `%`
        // were dropped — and `capture-pane -p -e -J` replays scrollback as result lines, so a repaint
        // lost every line of a tcsh or zsh session whose prompt is `%` (and `%<pane-id>` leads a
        // `list-panes` line the moment a format string starts with `#{pane_id}`). Worse, captured
        // content could forge protocol: a scrollback holding `%exit` set `serverEnded`, so the next
        // close looked like an orderly session end and no reconnect was attempted.
        //
        // A terminator whose number does *not* match cannot close the block: matching is what
        // distinguishes tmux's own frame from captured text that happens to look like one.
        if let active = activeCommandNumber {
            if let event = Self.blockTerminator(bytes, matching: active) {
                activeCommandNumber = nil
                return event
            }
            return .commandResultLine(commandNumber: active, line: Self.decode(bytes), bytes: Data(bytes))
        }

        // %output payloads are handled on bytes: the escaped form is ASCII, but the decoded
        // payload is arbitrary binary and must never round-trip through String.
        if Self.hasPrefix(bytes, "%output ") {
            return parseOutput(bytes, extended: false)
        }
        if Self.hasPrefix(bytes, "%extended-output ") {
            return parseOutput(bytes, extended: true)
        }

        let line = Self.decode(bytes)

        guard line.hasPrefix("%") else { return nil }

        var fields = line.split(separator: " ", omittingEmptySubsequences: false)
        let verb = String(fields.removeFirst())
        let args = fields.map(String.init)

        switch verb {
        case "%begin":
            guard args.count >= 2, let ts = Int64(args[0]), let num = Int(args[1]) else { return nil }
            sawFirstBegin = true
            activeCommandNumber = num
            return .begin(timestamp: ts, commandNumber: num, flags: args.count > 2 ? args[2] : "")

        case "%end", "%error":
            guard args.count >= 2, let ts = Int64(args[0]), let num = Int(args[1]) else { return nil }
            activeCommandNumber = nil
            let flags = args.count > 2 ? args[2] : ""
            return verb == "%end"
                ? .end(timestamp: ts, commandNumber: num, flags: flags)
                : .error(timestamp: ts, commandNumber: num, flags: flags)

        case "%layout-change":
            // `@w <layout> [<visible-layout> <flags>]` — three fields since tmux 2.5.
            guard args.count >= 2 else { return nil }
            return .layoutChange(
                windowId: args[0],
                layoutString: args[1],
                visibleLayout: args.count > 2 ? args[2] : nil,
                flags: args.count > 3 ? args[3] : nil
            )

        case "%window-add":
            guard let id = args.first else { return nil }
            return .windowAdd(windowId: id)

        case "%window-close":
            guard let id = args.first else { return nil }
            return .windowClose(windowId: id)

        case "%window-renamed":
            guard args.count >= 2 else { return nil }
            return .windowRenamed(windowId: args[0], name: args.dropFirst().joined(separator: " "))

        case "%window-pane-changed":
            guard args.count >= 2 else { return nil }
            return .windowPaneChanged(windowId: args[0], paneId: args[1])

        case "%session-changed":
            guard args.count >= 2 else { return nil }
            return .sessionChanged(sessionId: args[0], name: args.dropFirst().joined(separator: " "))

        case "%session-renamed":
            guard !args.isEmpty else { return nil }
            // tmux ≥ 2.4 sends `$id name`; older builds send just the name.
            if args.count >= 2, args[0].hasPrefix("$") {
                return .sessionRenamed(sessionId: args[0], name: args.dropFirst().joined(separator: " "))
            }
            return .sessionRenamed(sessionId: nil, name: args.joined(separator: " "))

        case "%session-window-changed":
            guard args.count >= 2 else { return nil }
            return .sessionWindowChanged(sessionId: args[0], windowId: args[1])

        case "%sessions-changed":
            return .sessionsChanged

        case "%unlinked-window-add":
            guard let id = args.first else { return nil }
            return .unlinkedWindowAdd(windowId: id)

        case "%unlinked-window-close":
            guard let id = args.first else { return nil }
            return .unlinkedWindowClose(windowId: id)

        case "%unlinked-window-renamed":
            guard args.count >= 2 else { return nil }
            return .unlinkedWindowRenamed(windowId: args[0], name: args.dropFirst().joined(separator: " "))

        case "%client-detached":
            return .clientDetached(client: args.first ?? "")

        case "%client-session-changed":
            guard args.count >= 3 else { return nil }
            return .clientSessionChanged(
                client: args[0],
                sessionId: args[1],
                name: args.dropFirst(2).joined(separator: " ")
            )

        case "%pause":
            guard let id = args.first else { return nil }
            return .pause(paneId: id)

        case "%continue":
            guard let id = args.first else { return nil }
            return .continuePane(paneId: id)

        case "%subscription-changed":
            // `<name> <session> <window> <window-index> <pane> : <value>`. The colon is a field of
            // its own, exactly as in `%extended-output`, and the value is everything after it — so it
            // is taken by position rather than by splitting, since a format's output may contain
            // spaces or colons of its own.
            guard args.count >= 6, args[5] == ":" else { return nil }
            let value = args.count > 6 ? args[6...].joined(separator: " ") : ""
            return .subscriptionChanged(
                name: args[0],
                sessionId: args[1],
                windowId: args[2],
                windowIndex: args[3],
                paneId: args[4],
                value: value
            )

        case "%pane-mode-changed":
            guard let id = args.first else { return nil }
            return .paneModeChanged(paneId: id)

        case "%config-error":
            return .configError(message: args.joined(separator: " "))

        case "%message":
            return .message(text: args.joined(separator: " "))

        case "%exit":
            return .exit(reason: args.isEmpty ? nil : args.joined(separator: " "))

        default:
            return .unknownNotification(line: line)
        }
    }

    /// `%end <ts> <num> [flags]` / `%error <ts> <num> [flags]`, and only for the command whose block
    /// is open. Returns nil for anything else, including a well-formed terminator carrying a
    /// different number — that is content, not framing.
    private static func blockTerminator(_ bytes: [UInt8], matching commandNumber: Int) -> ControlEvent? {
        let isEnd = hasPrefix(bytes, "%end ")
        guard isEnd || hasPrefix(bytes, "%error ") else { return nil }

        var fields = decode(bytes).split(separator: " ", omittingEmptySubsequences: false)
        fields.removeFirst()
        guard fields.count >= 2,
              let ts = Int64(fields[0]),
              let num = Int(fields[1]),
              num == commandNumber
        else { return nil }

        let flags = fields.count > 2 ? String(fields[2]) : "0"
        return isEnd
            ? .end(timestamp: ts, commandNumber: num, flags: flags)
            : .error(timestamp: ts, commandNumber: num, flags: flags)
    }

    // MARK: - Output payloads

    private func parseOutput(_ bytes: [UInt8], extended: Bool) -> ControlEvent? {
        var i = 0
        let n = bytes.count
        let space = UInt8(ascii: " ")

        func nextField() -> [UInt8]? {
            guard i < n else { return nil }
            let start = i
            while i < n && bytes[i] != space { i += 1 }
            let field = Array(bytes[start..<i])
            if i < n { i += 1 }  // consume the separator
            return field
        }

        guard nextField() != nil else { return nil }               // verb
        guard let paneField = nextField(), !paneField.isEmpty else { return nil }
        let paneId = Self.decode(paneField)

        var age = 0
        if extended {
            guard let ageField = nextField(), let parsed = Int(Self.decode(ageField)) else { return nil }
            age = parsed
            // tmux writes `%extended-output %p <age> : <data>`. The colon is a reserved slot for
            // future fields; skip everything up to and including it so it never lands in the payload.
            //
            // Failing the parse when it is absent, rather than running off the end: consuming the
            // whole line looking for a colon that is not there used to leave `i == n`, so the event
            // was emitted with *empty data* and the pane went silently dead. A build that varies the
            // reserved fields would have stopped every pane at once with nothing in the log. A parse
            // failure at least says so, and `pause-after` — which is what switches the server into
            // this mode — is only enabled on 3.2 and above.
            var sawColon = false
            while i < n {
                guard let field = nextField() else { break }
                if field == [UInt8(ascii: ":")] {
                    sawColon = true
                    break
                }
            }
            guard sawColon else { return nil }
        }

        let payload = i < n ? Array(bytes[i...]) : []
        let data = Data(Self.unescapeOctal(payload))
        return extended
            ? .extendedOutput(paneId: paneId, age: age, data: data)
            : .output(paneId: paneId, data: data)
    }

    /// Decodes tmux's octal escaping (`\012`, `\000`, `\\`) back to raw bytes.
    public static func unescapeOctal(_ bytes: [UInt8]) -> [UInt8] {
        let backslash = UInt8(ascii: "\\")
        // Nothing to do for the overwhelmingly common all-printable case.
        guard bytes.contains(backslash) else { return bytes }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == backslash else {
                result.append(bytes[i])
                i += 1
                continue
            }
            if i + 3 < bytes.count,
               isOctalDigit(bytes[i + 1]), isOctalDigit(bytes[i + 2]), isOctalDigit(bytes[i + 3]) {
                let value = (Int(bytes[i + 1] - 48) << 6) | (Int(bytes[i + 2] - 48) << 3) | Int(bytes[i + 3] - 48)
                result.append(UInt8(truncatingIfNeeded: value))
                i += 4
            } else if i + 1 < bytes.count, bytes[i + 1] == backslash {
                result.append(backslash)
                i += 2
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - Byte helpers

    private static func isOctalDigit(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "7")
    }

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard bytes.count >= p.count else { return false }
        return Array(bytes[0..<p.count]) == p
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }

    /// Lossy by design: only used for protocol text, never for pane payloads.
    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
