import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
// `forkpty` lives in libutil on glibc and is not re-exported by the Glibc module.
import CUtil
#endif

/// `write(2)`, named unambiguously.
///
/// Swift resolves a bare `write` to `PtyTransport.write(_:)` inside the type, which is why the call
/// site qualified it — but it qualified it as `Darwin.write`, outside any `#if`, fifteen lines after
/// the file carefully chose between Darwin and Glibc. That single unqualified reference was enough to
/// make `tetmuxCore` fail to build on Linux, which is the whole §2.4 hedge, and nothing noticed
/// because CI had no Linux job to notice with.
@inline(__always)
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buffer, count)
    #else
    return Glibc.write(fd, buffer, count)
    #endif
}

public enum PtyError: Error, CustomStringConvertible, Sendable {
    case alreadySpawned
    case openFailed(String, code: Int32)
    case forkFailed(code: Int32)
    case executableNotFound(String)
    /// The child exited before or during the session. `code` 127 means exec itself failed.
    case childExited(code: Int32)
    case childSignalled(signal: Int32)
    /// A command reached tmux in part. The framing is broken and cannot be repaired from this side.
    case writeTruncated(bytesWritten: Int, of: Int)
    /// The process started but never spoke the control protocol.
    case handshakeTimedOut(seconds: Int)

    public var description: String {
        switch self {
        case .alreadySpawned:
            return "This transport has already been used; create a new one."
        case .openFailed(let what, let code):
            return "\(what) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .forkFailed(let code):
            return "fork failed: \(String(cString: strerror(code))) (errno \(code))"
        case .executableNotFound(let name):
            return "Executable not found on PATH: \(name)"
        case .childExited(let code):
            return code == 127
                ? "Command could not be executed (exit 127)"
                : "Process exited with status \(code)"
        case .childSignalled(let signal):
            return "Process terminated by signal \(signal)"
        case .writeTruncated(let written, let total):
            return "Only \(written) of \(total) bytes reached tmux; the command stream is out of frame"
        case .handshakeTimedOut(let seconds):
            return "No response from tmux within \(seconds)s"
        }
    }
}

/// A child process running on the far end of a pseudo-terminal.
///
/// The control-mode channel (§2.1) is the only abstraction the layers above need: local and remote
/// differ solely in which executable gets spawned here.
///
/// Fork safety is the delicate part. Between `fork()` and `execve()` the child may call only
/// async-signal-safe functions — no Swift allocation, no ARC traffic, no `Foundation`. In a process
/// with a running Swift concurrency pool, another thread can hold the malloc lock at the instant we
/// fork, and the child then deadlocks on the first allocation, forever, with no diagnostic. So every
/// C string, the argv/envp vectors, the termios struct, and the signal mask are all built *before*
/// the fork; the child only issues syscalls.
public final class PtyTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var hasSpawned = false
    private var terminated = false

    public init() {}

    deinit {
        terminate()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return masterFd >= 0 && !terminated
    }

    /// Resolves a bare command name against `PATH`. `execve` needs an absolute path, and doing the
    /// search here keeps the post-fork child free of anything that allocates.
    public static func resolveExecutable(_ name: String, path: String? = nil) -> String? {
        if name.contains("/") {
            return access(name, X_OK) == 0 ? name : nil
        }
        let searchPath = path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in searchPath.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// Spawns `executable` on a fresh PTY and streams everything it writes.
    ///
    /// The stream finishes on EOF, or throws `PtyError.childExited` when the child failed — which is
    /// how an `ssh` authentication failure or a missing remote `tmux` reaches the UI.
    public func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        initialSize: (cols: UInt16, rows: UInt16) = (80, 24)
    ) throws -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        guard !hasSpawned else {
            lock.unlock()
            throw PtyError.alreadySpawned
        }
        hasSpawned = true
        lock.unlock()

        // A write to a PTY whose child has exited raises SIGPIPE, which would kill the whole app.
        signal(SIGPIPE, SIG_IGN)

        guard let resolvedPath = Self.resolveExecutable(executable) else {
            throw PtyError.executableNotFound(executable)
        }

        // ---- Everything below is allocated before the fork. ----

        let argv = CStringVector([resolvedPath] + arguments)
        let envp = CStringVector((environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" })
        let execPath = strdup(resolvedPath)!

        // Trivial local copies. The child reads only these, so it performs no ARC traffic and
        // touches no Swift metadata between the fork and the exec.
        let argvPointer = argv.pointer
        let envpPointer = envp.pointer

        // Raw mode (§2.1): no echo of the commands we write, and no CR translation on input.
        // `forkpty` applies this to the slave itself, so the child needs no tcsetattr call.
        var slaveTermios = termios()
        cfmakeraw(&slaveTermios)
        var windowSize = winsize(ws_row: initialSize.rows, ws_col: initialSize.cols, ws_xpixel: 0, ws_ypixel: 0)

        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)

        // ---- fork ----

        // `forkpty` rather than a hand-rolled fork: the openpt/grantpt/setsid/TIOCSCTTY/dup2 dance
        // happens inside libutil's C, so the child gets a real controlling terminal — which ssh
        // needs to prompt on /dev/tty — without any of it running through the Swift runtime.
        var master: Int32 = -1
        let pid = forkpty(&master, nil, &slaveTermios, &windowSize)
        if pid < 0 {
            let e = errno
            free(execPath)
            throw PtyError.forkFailed(code: e)
        }

        if pid == 0 {
            // Child. Only async-signal-safe calls from here to execve.
            //
            // Foundation and the concurrency runtime leave signals blocked and handled in ways the
            // child must not inherit; ssh in particular needs default SIGINT behaviour.
            _ = sigprocmask(SIG_SETMASK, &emptySignalMask, nil)
            signal(SIGPIPE, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            signal(SIGHUP, SIG_DFL)

            _ = execve(execPath, argvPointer, envpPointer)
            _exit(127)
        }

        // Parent. The child has its own copy-on-write view of all of this.
        free(execPath)
        withExtendedLifetime((argv, envp)) {}

        // Non-blocking + poll(): no data means the thread sleeps in the kernel, not a 5 ms spin.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        masterFd = master
        childPid = pid
        lock.unlock()

        return makeReadStream(fd: master, pid: pid)
    }

    private func makeReadStream(fd: Int32, pid: pid_t) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            // A dedicated thread rather than a Task: this loop blocks in poll() for the lifetime of
            // the connection and must never occupy a slot in the cooperative thread pool.
            let thread = Thread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 65536)

                readLoop: while true {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&pfd, 1, 1000)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if ready == 0 {
                        // Timed out. Re-check that we have not been torn down under us.
                        if self?.isRunning != true { break }
                        continue
                    }

                    // Drain everything available before going back to poll(), so a fast producer
                    // costs one syscall per chunk rather than one per wakeup.
                    while true {
                        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                        if n > 0 {
                            continuation.yield(Data(buffer[0..<n]))
                            if n < buffer.count { break }
                        } else if n == 0 {
                            break readLoop  // EOF: the child closed the far side.
                        } else {
                            if errno == EAGAIN || errno == EWOULDBLOCK { break }
                            if errno == EINTR { continue }
                            break readLoop
                        }
                    }
                }

                // The reader owns the descriptor and is the only thing that closes it.
                //
                // `terminate()` used to close it while this thread was sitting in a 1000 ms `poll` on
                // the number — so a reconnect fast enough to be handed the same fd back had its bytes
                // read by the *old* stream and yielded into a channel that was already finished. The
                // new channel then saw a stream with a hole in it, which is a missing `%begin` and a
                // permanently misaligned command queue, or a missing handshake and a host that never
                // finishes connecting. Closing here instead means the number cannot be reissued until
                // nothing is using it. The cost is that the fd outlives `terminate` by up to the poll
                // timeout, which nothing depends on.
                close(fd)
                let status = self?.reapChild() ?? 0
                if let error = Self.exitError(status: status) {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            thread.name = "tetmux.pty.read"
            thread.stackSize = 512 * 1024
            thread.start()

            continuation.onTermination = { [weak self] _ in
                self?.terminate()
            }
        }
    }

    private static func exitError(status: Int32) -> PtyError? {
        guard status != 0 else { return nil }
        if status & 0x7f != 0 {
            let sig = status & 0x7f
            // A SIGTERM/SIGHUP here is us shutting the channel down deliberately.
            return (sig == SIGTERM || sig == SIGHUP) ? nil : .childSignalled(signal: sig)
        }
        return .childExited(code: (status >> 8) & 0xff)
    }

    /// What became of a write. The distinction between the two failures is the whole point:
    /// control-mode commands are newline-framed, so a command that went out *in part* has put a
    /// fragment with no terminator in front of tmux's parser. The next command written concatenates
    /// onto it and tmux answers one block for what the caller counted as two — which misaligns the
    /// pending-command FIFO for the life of the channel, silently. Nothing can retract those bytes
    /// and nothing can discover how many of them tmux consumed, so a partial write is not a failed
    /// command: it is a channel that can no longer be spoken on.
    public enum WriteOutcome: Sendable, Equatable {
        case complete
        /// Not one byte left, so the command simply did not happen and the caller can unqueue it.
        case nothingWritten
        /// A fragment is in tmux's input and the framing is broken. The channel must be torn down.
        case partial(bytesWritten: Int)
    }

    /// Writes a control-mode command. Short writes and a temporarily full PTY buffer are handled;
    /// a genuinely wedged channel gives up rather than blocking the caller forever.
    @discardableResult
    public func write(_ data: Data) -> WriteOutcome {
        lock.lock()
        let fd = masterFd
        let alive = !terminated
        lock.unlock()
        guard fd >= 0, alive, !data.isEmpty else { return .nothingWritten }

        return data.withUnsafeBytes { raw -> WriteOutcome in
            guard let base = raw.baseAddress else { return .nothingWritten }
            var written = 0
            var retries = 0
            func give(up: Void = ()) -> WriteOutcome {
                written == 0 ? .nothingWritten : .partial(bytesWritten: written)
            }
            while written < raw.count {
                let n = posixWrite(fd, base.advanced(by: written), raw.count - written)
                if n > 0 {
                    written += n
                    retries = 0
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    retries += 1
                    if retries > 1000 { return give() }  // ~1 s of a jammed channel
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1)
                } else {
                    return give()
                }
            }
            return .complete
        }
    }

    /// Propagates the terminal size to the child. For `ssh -tt` this also travels to the remote
    /// PTY, which is how a remote tmux learns the client resized.
    public func resize(cols: UInt16, rows: UInt16) {
        lock.lock()
        let fd = masterFd
        lock.unlock()
        guard fd >= 0, cols > 0, rows > 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    /// Whether this transport still holds `pid` — i.e. nothing has waited on it yet, so the number
    /// still refers to our child rather than to whatever the kernel has since reissued it to.
    private func stillOwns(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return childPid == pid
    }

    /// Blocks briefly to collect the child's exit status so it does not linger as a zombie.
    @discardableResult
    private func reapChild() -> Int32 {
        lock.lock()
        let pid = childPid
        childPid = -1
        lock.unlock()
        guard pid > 0 else { return 0 }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return 0 }
        }
        return status
    }

    /// Closes the channel and stops the child. Safe to call more than once and from any thread.
    public func terminate() {
        lock.lock()
        if terminated {
            lock.unlock()
            return
        }
        terminated = true
        let pid = childPid
        // Stops any further writes. The descriptor itself is closed by the read thread, which is the
        // only thing still touching it — see `makeReadStream`.
        masterFd = -1
        lock.unlock()

        if pid > 0 {
            // SIGHUP first: ssh and tmux both treat it as "the terminal went away" and exit
            // cleanly, detaching rather than killing anything on the remote side. It is also what
            // makes the read thread's poll return EOF, so it stops promptly rather than at its
            // timeout.
            kill(pid, SIGHUP)
        }
        if pid > 0 {
            // Give it a moment, then insist. Reaped either way by the read thread or here.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                // Only if this pid is still ours. `reapChild` clears `childPid` once it has waited on
                // it, and after that the number belongs to the kernel to reissue — signalling it would
                // eventually land on an unrelated process of the user's.
                guard let self, self.stillOwns(pid: pid) else { return }
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
            }
        }
    }
}

/// A NULL-terminated `char *[]` built before a fork and freed after it.
private final class CStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[count] = nil
    }

    deinit {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
