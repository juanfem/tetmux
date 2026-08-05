import Foundation

/// A command that is asked one question and then goes away.
///
/// Deliberately not `PtyTransport`, which is the only spawner of anything a *channel* runs on. A
/// probe is not a channel: it speaks no protocol, holds no state, and is thrown away with its
/// answer — the same category as `HostConfigStore.resolveEffectiveConfig`'s `ssh -G`. The difference
/// that matters is the pty. `forkpty` would give ssh a controlling terminal, which is exactly what it
/// needs to prompt for a password on; a pipe leaves it nowhere to ask, which is half of F4.4's
/// promise that discovery cannot interrupt anybody (`BatchMode=yes` is the other half).
///
/// `stdin` is `/dev/null` for every probe, and that is load-bearing rather than tidy: `tmux -C`
/// reads commands until its input ends, so a probe given a live stdin prints its answer and then
/// waits forever.
public enum CommandProbe {
    public struct Result: Sendable {
        /// Exit status, or -1 if the process could not be started or had to be killed.
        public let status: Int32
        /// stdout and stderr together, in arrival order.
        public let output: Data
        public let timedOut: Bool
    }

    /// Runs `executable` and returns everything it wrote.
    ///
    /// stderr is merged into the same pipe rather than discarded: what a failing probe says is the
    /// only diagnosis there is, and the framing is what separates it from the answer — a caller
    /// parsing `%begin` blocks is unbothered by a banner or an ssh complaint sharing the stream.
    ///
    /// The whole thing runs on a detached task, because `Process` blocks the thread it reads on and
    /// callers are actors: a probe that ran on the actor would hold every other host's channel still
    /// for as long as ssh took to answer.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(10)
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                answer.resume(Result(status: -1, output: Data(), timedOut: false))
                return
            }

            // The bound is not a formality, and it has to be able to fire *whatever* the reader is
            // doing. Reading to EOF waits for every writer to let the pipe go, and an ssh that has
            // left a `ControlMaster` behind is a writer that outlives the command — so the read can
            // block after the process we started is dead. Discovery asks for `ControlMaster=no`
            // precisely so that cannot happen; this is what makes the failure survivable if it does.
            let deadline = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                answer.resume(Result(status: -1, output: Data(), timedOut: true))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Double(timeout.components.seconds), execute: deadline
            )

            // A dedicated thread, for the same reason `PtyTransport`'s reader is one: this blocks,
            // and a blocking call in the cooperative pool occupies a slot that the actors — every
            // channel in the app — are waiting on. A probe fires on window focus, so getting this
            // wrong would trade "discovery is slow" for "nothing in the app runs".
            let thread = Thread {
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                answer.resume(Result(status: process.terminationStatus, output: output, timedOut: false))
            }
            thread.name = "tetmux.probe"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    /// Resumes a continuation exactly once, from whichever of the reader and the deadline gets there
    /// first. Resuming twice is a crash, and this is a race by construction.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?

        init(_ continuation: CheckedContinuation<Result, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: Result) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }
    }
}
