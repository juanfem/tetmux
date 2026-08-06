import AppKit
import Foundation
import os

/// P6.1 — keypress → glyph, instrumented where the two ends actually are.
///
/// The requirement is 12 ms at p95 on a local session, and until this existed nothing in the tree
/// had ever timed anything: the `P6` citations in the source are design rationale. What makes the
/// number hard to get honestly is that both ends are in code we do not own. The keystroke arrives at
/// SwiftTerm's `TerminalView.keyDown`, and the glyph appears when AppKit draws that view — so the
/// interval is opened and closed from `PaneTerminalView`, which is the one subclass of it we have,
/// rather than from anywhere in `tetmuxCore` where the timing would be of the protocol layer alone.
///
/// Three points, not two, because the two halves fail differently and a single number cannot say
/// which one moved:
///
///   * **keyDown** — the `NSEvent`, taken from `KeyEventMonitor`. A local monitor is the earliest
///     this process sees a keystroke: `NSApplication.sendEvent` calls monitors before it dispatches
///     key equivalents, so this is ahead of the menu, ahead of the responder chain and ahead of
///     SwiftTerm deciding what bytes the key means.
///   * **echo** — the byte comes back in an `%output` chunk. Everything between this and the first
///     point is off-machine or nearly: the 8 ms input coalescing, the write, tmux, the read. On a
///     local session this is most of the budget.
///   * **draw** — the pane has drawn. Neither end could be an override of `TerminalView`: SwiftTerm
///     declares `keyDown` and `draw` `public` rather than `open`, which closes them to a subclass in
///     another module. The keystroke end had a better hook to move to. The draw end has none, so
///     what closes the interval is a 1×1 overlay *subview* of the pane, marked dirty when the echo
///     lands — AppKit draws a view's own content before its subviews, so the overlay's `draw` runs
///     in the same cycle, after the terminal has painted. Closing it from `viewWillDraw` on the pane
///     itself was the alternative and would understate every sample by one full-screen draw.
///
/// Matching is by *byte*: the character the user typed is looked for in the chunks that follow.
/// A shell or `cat` echoes it, so on a quiet pane the first occurrence is the echo of that
/// keystroke. It is not proof — a pane printing the same letter for its own reasons would satisfy
/// it — which is why the measurement procedure specifies a quiet pane, and why this is a local
/// harness rather than something that runs unattended.
///
/// **Off unless asked.** `isEnabled` is read once: the environment variable the measurement script
/// sets, or a signpost trace being live. Disabled, this costs one boolean test at each of the three
/// points and nothing else — in particular the byte scan over `%output` never runs, which matters
/// because that is the path P6.3 is a promise about.
@MainActor
final class LatencyProbe {
    static let shared = LatencyProbe()

    /// The environment variable `Scripts/measure-latency.sh` sets.
    static let environmentKey = "TETMUX_MEASURE_LATENCY"

    private let signposter = OSSignposter(
        subsystem: "org.tetmux", category: "Latency"
    )

    /// Whether anything at all is recorded.
    ///
    /// Either the script asked, or Instruments is recording — `signposter.isEnabled` is false unless
    /// a trace is live, which is what makes leaving the calls in the shipping binary free. Read once
    /// and stored: this is tested on every keystroke and every chunk of pane output.
    let isEnabled: Bool

    /// Whether samples are also written to stderr for a script to read.
    ///
    /// Signposts alone would mean exporting a `.trace` and parsing its XML to get a percentile out,
    /// which is a lot of fragile machinery between the measurement and the number. The signposts
    /// stay, because they are what puts a slow sample next to the CPU trace that explains it; this
    /// is what makes the common case one script and no Instruments at all.
    private let printsSamples: Bool

    private init() {
        printsSamples = ProcessInfo.processInfo.environment[Self.environmentKey] != nil
        isEnabled = printsSamples || signposter.isEnabled
    }

    /// One keystroke in flight. Deliberately one, not a queue: two keystrokes overlapping would be
    /// two intervals whose ends cannot be told apart, and the procedure types slower than the round
    /// trip for exactly that reason. A second keystroke before the first has been drawn abandons the
    /// first rather than mismeasuring it, and says so in the count.
    private struct Pending {
        let byte: UInt8
        let start: ContinuousClock.Instant
        let id: OSSignpostID
        let state: OSSignpostIntervalState
        /// The overlay whose draw closes this interval. Weak: the pane can go while a sample is in
        /// flight, and a measurement is not a reason to keep a terminal alive.
        weak var overlay: DrawProbeView?
        var echoed: ContinuousClock.Duration?
    }

    /// Closes P6.1's interval from inside the pane's draw cycle.
    ///
    /// A subview rather than the pane itself, because SwiftTerm's `draw` cannot be overridden from
    /// here. 1×1 and transparent: it has to be big enough that AppKit does not skip it and small
    /// enough to cost nothing, and it must never take a mouse event from the terminal underneath —
    /// hence `hitTest` returning nil rather than merely `isHidden`, which would stop it drawing too.
    private final class DrawProbeView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            LatencyProbe.shared.didDraw()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
    }

    private var pending: Pending?
    private let clock = ContinuousClock()

    /// Samples that were abandoned because the next keystroke arrived first. Reported with the rest:
    /// a run where half the keystrokes overlapped is a run whose p95 means something else.
    private(set) var abandoned = 0

    /// The keystroke arrived, at the pane it is going to. `character` is what a quiet pane echoes.
    func keyDown(_ character: UInt8, in pane: NSView) {
        guard isEnabled else { return }
        if pending != nil {
            abandoned += 1
            // Reported, not just counted: a run where a third of the keystrokes overlapped has a
            // p95 that means something else, and the script cannot see that from the samples that
            // did complete. The signpost interval is deliberately left to expire rather than ended
            // at a moment that means nothing — an unterminated interval is visible in Instruments
            // as exactly what it is.
            if printsSamples { FileHandle.standardError.write(Data("LATENCY-DROP\n".utf8)) }
            pending = nil
        }
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("keypress", id: id)
        pending = Pending(
            byte: character, start: clock.now, id: id, state: state, overlay: overlay(on: pane)
        )
    }

    /// This pane's draw probe, installed on first use.
    ///
    /// Lazily and never at construction, so a build nobody is measuring has no extra view in any
    /// pane at all — and so the overlay lands on the pane actually being typed into rather than on
    /// whichever was created last.
    private func overlay(on pane: NSView) -> DrawProbeView {
        if let existing = pane.subviews.compactMap({ $0 as? DrawProbeView }).first { return existing }
        let probe = DrawProbeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        pane.addSubview(probe)
        return probe
    }

    /// A chunk of `%output` for a pane, before it is fed to the emulator.
    func observeOutput(_ bytes: [UInt8]) {
        guard isEnabled, var sample = pending, sample.echoed == nil else { return }
        guard bytes.contains(sample.byte) else { return }
        sample.echoed = clock.now - sample.start
        pending = sample
        // On the interval's own id, so Instruments shows it inside the interval rather than as a
        // loose event that has to be lined up by eye.
        signposter.emitEvent("echo", id: sample.id)
        // Marked here rather than relying on the terminal's own dirty rect: SwiftTerm invalidates
        // the cells that changed, and a 1×1 overlay in the corner does not intersect them, so
        // without this it would not be drawn in the cycle that paints the glyph.
        sample.overlay?.needsDisplay = true
    }

    /// The view drew. Only the first draw *after* the echo closes the interval: a draw before it is
    /// a cursor blink or a repaint of something else, and taking it would report a latency shorter
    /// than the round trip that has not finished.
    func didDraw() {
        guard isEnabled, let sample = pending, let echoed = sample.echoed else { return }
        let total = clock.now - sample.start
        pending = nil
        signposter.endInterval("keypress", sample.state)
        guard printsSamples else { return }
        // One line per sample, and the script does the statistics. The alternative — percentiles
        // computed in here — puts the part that can be quietly wrong inside the thing being
        // measured, where nobody can check it against the raw samples.
        FileHandle.standardError.write(Data(
            String(format: "LATENCY %.3f %.3f\n", total.milliseconds, echoed.milliseconds).utf8
        ))
    }
}

extension Duration {
    /// Milliseconds as a `Double`. `components` is (seconds, attoseconds); there is no lossy
    /// conversion in the standard library and rolling one by hand at each call site is how the
    /// attosecond term gets dropped.
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
