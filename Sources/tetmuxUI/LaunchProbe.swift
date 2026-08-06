import AppKit
import Darwin
import Foundation

/// P6.7's second half — exec to first frame, timed by the application rather than by a tracer.
///
/// `Scripts/measure-launch.sh` gets this number from Instruments' App Launch template, which is the
/// right instrument for *where* the time goes: it breaks the launch into named phases, and that is
/// what said the cost was in AppKit Scene Creation rather than in anything tetmux does. What it
/// cannot do is say how much of the total the user would actually pay, because the tracer is inside
/// every number it produces — and the measured share turned out not to be a rounding error. Under
/// that template `Initializing - Process Creation` is ~290 ms for tetmux and **413 ms for
/// Calculator**, an application with no scene of ours in it at all: the phase is dominated by
/// `xctrace` getting a process launched under ktrace, not by the program being launched.
///
/// So this exists to answer the one question the trace cannot: with nobody watching, how long from
/// `exec` to the first frame. Two ends, both taken from outside the process's own bookkeeping:
///
///   * **exec** — `kp_proc.p_starttime` out of `sysctl(KERN_PROC_PID)`, which is the kernel's record
///     of when this process began. Not a mark taken in `main`, which would start the clock after
///     dyld has already done its work and would flatter the number by exactly the part P6.7's
///     "cold" case is about.
///   * **first frame** — a 1×1 probe view added to the window's content view at
///     `applicationDidFinishLaunching`, reporting its own first `draw`. The same trick
///     `LatencyProbe` closes P6.1 with, for the same reason: AppKit draws a view's own content
///     before its subviews, so this runs in the cycle that put the window on screen. It matches
///     what App Launch calls the end of Initial Frame Rendering to within a draw.
///
/// **Off unless asked**, like the latency probe: no environment variable, no view, no `sysctl`.
@MainActor
enum LaunchProbe {
    /// The environment variable `Scripts/measure-launch.sh` sets for its untraced pass.
    static let environmentKey = "TETMUX_MEASURE_LAUNCH"

    private final class FirstFrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            LaunchProbe.reportFirstFrame()
            // Reported once and then gone: a probe left in the window would be redrawn for the life
            // of the process, and the second report is not a launch.
            removeFromSuperview()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
    }

    private static var reported = false

    /// Installs the probe, if a measurement asked for one. Called from
    /// `applicationDidFinishLaunching`, which the trace puts after scene creation and before the
    /// first frame — the window exists by then and has not yet drawn.
    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment[environmentKey] != nil else { return }
        guard let content = NSApp.windows.first(where: { $0.contentView != nil })?.contentView else {
            // No window at this point is not a failure to report — it is a launch that has not put
            // one on screen, which is a different measurement and should not be quietly filled in
            // with the next window the user happens to open.
            FileHandle.standardError.write(Data("LAUNCH-NOWINDOW\n".utf8))
            return
        }
        content.addSubview(FirstFrameView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
    }

    fileprivate static func reportFirstFrame() {
        guard !reported else { return }
        reported = true
        guard let started = processStart() else {
            FileHandle.standardError.write(Data("LAUNCH-NOSTART\n".utf8))
            return
        }
        var now = timeval()
        gettimeofday(&now, nil)
        let milliseconds = Double(now.tv_sec - started.tv_sec) * 1000
            + Double(Int(now.tv_usec) - Int(started.tv_usec)) / 1000
        FileHandle.standardError.write(Data(String(format: "LAUNCH %.1f\n", milliseconds).utf8))
    }

    /// When the kernel says this process started.
    ///
    /// `KERN_PROC_PID` rather than anything in `ProcessInfo`: `systemUptime` is a clock reading and
    /// says nothing about when `exec` happened, and there is no API that reports it. The `timeval`
    /// is on the same wall clock `gettimeofday` reads, which is what makes the subtraction legal.
    private static func processStart() -> timeval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}
