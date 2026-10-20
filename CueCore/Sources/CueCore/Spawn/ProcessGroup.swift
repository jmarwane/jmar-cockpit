import Darwin
import Foundation
import Synchronization

/// How a spawned process ended.
public enum Termination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}

public struct SpawnError: Error, Sendable, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }
}

/// A process started in its own process group. The group ID equals the leader's PID.
public final class SpawnedProcess: Sendable {
    public let pid: pid_t
    public var processGroupID: pid_t { pid }

    /// Combined stdout and stderr, when the spawn asked for it.
    public let output: OutputCollector?

    private let exit = ExitWaiter()

    init(pid: pid_t, output: OutputCollector?) {
        self.pid = pid
        self.output = output
        let exit = self.exit
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            exit.resolve(Termination(waitStatus: status))
        }
        thread.name = "Cue reaper \(pid)"
        thread.start()
    }

    /// The leader's termination, once it has been reaped.
    public var termination: Termination? { exit.result }

    /// Waits for the group leader to exit.
    public func waitForExit() async -> Termination { await exit.wait() }

    /// Waits for the group leader to exit, or returns nil after `timeout`.
    public func waitForExit(timeout: Duration) async -> Termination? {
        await withTimeout(timeout) { await self.waitForExit() }
    }

    /// True while any process in the group still exists.
    public var groupIsAlive: Bool { ProcessGroup.isAlive(processGroupID) }

    /// SIGTERM to the whole group, then SIGKILL to the group if anything is left after `grace`.
    /// Returns once no process in the group remains, or after a final short wait.
    @discardableResult
    public func terminateGroup(grace: Duration = .seconds(5)) async -> Bool {
        let pgid = processGroupID
        guard ProcessGroup.isAlive(pgid) else { return true }
        kill(-pgid, SIGTERM)
        if await ProcessGroup.waitUntilGone(pgid, timeout: grace) { return true }
        kill(-pgid, SIGKILL)
        return await ProcessGroup.waitUntilGone(pgid, timeout: .seconds(2))
    }
}

public enum ProcessGroup {
    /// Spawns `executable` in a new process group, with stdin from /dev/null.
    /// When `captureOutput` is set, stdout and stderr go to one pipe read by an `OutputCollector`;
    /// otherwise both go to /dev/null.
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        captureOutput: Bool = true,
        outputLimit: Int = 256 * 1024
    ) throws(SpawnError) -> SpawnedProcess {
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Own process group, default signal handlers, empty signal mask, and no inherited
        // descriptors other than the three set up below.
        var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        var pipeFDs: [Int32] = [-1, -1]
        if captureOutput {
            guard pipe(&pipeFDs) == 0 else { throw SpawnError(operation: "pipe", code: errno) }
            // Keep both ends out of anything else this app spawns; dup2 clears the flag for the child.
            pipeFDs.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        if let workingDirectory {
            posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        if captureOutput { close(pipeFDs[1]) }
        guard result == 0 else {
            if captureOutput { close(pipeFDs[0]) }
            throw SpawnError(operation: "posix_spawn \(executable)", code: result)
        }

        let collector = captureOutput ? OutputCollector(readingFrom: pipeFDs[0], limit: outputLimit) : nil
        return SpawnedProcess(pid: pid, output: collector)
    }

    /// True while any process in group `pgid` exists.
    public static func isAlive(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    /// Polls every 50 ms until no process in the group remains. Returns false on timeout.
    public static func waitUntilGone(_ pgid: pid_t, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isAlive(pgid) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

/// Resolves once with the leader's termination and wakes every waiter.
final class ExitWaiter: Sendable {
    private struct State {
        var result: Termination?
        var waiters: [CheckedContinuation<Termination, Never>] = []
    }

    private let state = Mutex(State())

    var result: Termination? { state.withLock { $0.result } }

    func resolve(_ termination: Termination) {
        let waiters = state.withLock { state in
            state.result = termination
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: termination) }
    }

    func wait() async -> Termination {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Termination? in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
