import Darwin
import Foundation
import Synchronization

public enum RunError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case launch(LaunchError)
    case spawn(SpawnError)

    public var description: String {
        switch self {
        case .alreadyRunning: "Already running"
        case .launch(let error): error.description
        case .spawn(let error): "Couldn't start: \(String(cString: strerror(error.code)))"
        }
    }
}

/// Starts commands and keeps at most one active run per item.
public actor Runner {
    private var active: [UUID: RunHandle] = [:]

    public init() {}

    public func start(_ id: UUID, launch: LaunchSpec, timeLimit: Duration? = nil) throws(RunError) -> RunHandle {
        if let existing = active[id], existing.isActive { throw .alreadyRunning }
        let process: SpawnedProcess
        do {
            process = try ProcessGroup.spawn(
                executable: launch.shell,
                arguments: launch.arguments,
                environment: launch.environment,
                workingDirectory: launch.workingDirectory,
                output: .capture(redactor: launch.redactor)
            )
        } catch {
            throw .spawn(error)
        }
        let handle = RunHandle(process: process, command: launch.command, timeLimit: timeLimit)
        active[id] = handle
        Task {
            _ = await handle.result()
            self.finished(id, handle)
        }
        return handle
    }

    /// The active run for an item, if any.
    public func handle(for id: UUID) -> RunHandle? {
        guard let handle = active[id], handle.isActive else { return nil }
        return handle
    }

    public var activeIDs: [UUID] { active.filter { $0.value.isActive }.map(\.key) }

    /// Cancels an item's active run: SIGTERM to its group, then SIGKILL after `grace`.
    public func cancel(_ id: UUID, grace: Duration = .seconds(5)) async {
        await handle(for: id)?.cancel(grace: grace)
    }

    private func finished(_ id: UUID, _ handle: RunHandle) {
        if active[id] === handle { active[id] = nil }
    }
}

/// One running command. Its result is ready once the group leader exits.
public final class RunHandle: Sendable {
    private struct Flags {
        var cancelled = false
        var timedOut: Duration?
    }

    public let process: SpawnedProcess
    public let output: RunOutput
    public let command: String
    public let startedAt: Date

    public var pid: pid_t { process.pid }

    private let flags = Mutex(Flags())
    private let finished = Mutex<RunResult?>(nil)
    private let waiters = Mutex<[CheckedContinuation<RunResult, Never>]>([])

    init(process: SpawnedProcess, command: String, timeLimit: Duration?) {
        self.process = process
        self.output = process.output ?? RunOutput()
        self.command = command
        self.startedAt = Date()

        Task { [self] in
            let termination = await process.waitForExit()
            // Something left in the background may hold the pipes open; don't wait on it for long.
            _ = await output.waitForEnd(timeout: .seconds(1))
            resolve(makeResult(termination))
        }
        if let timeLimit {
            Task { [self] in
                try? await Task.sleep(for: timeLimit)
                guard isActive else { return }
                flags.withLock { $0.timedOut = timeLimit }
                await process.terminateGroup(grace: .seconds(5))
            }
        }
    }

    /// True until the group leader has exited and the result is ready.
    public var isActive: Bool { finished.withLock { $0 == nil } }

    /// True while any process in the run's group exists.
    public var groupIsAlive: Bool { process.groupIsAlive }

    public var finishedResult: RunResult? { finished.withLock { $0 } }

    public func result() async -> RunResult {
        await withCheckedContinuation { continuation in
            let ready = finished.withLock { result -> RunResult? in
                if let result { return result }
                waiters.withLock { $0.append(continuation) }
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Marks the run cancelled and stops its whole group.
    public func cancel(grace: Duration = .seconds(5)) async {
        flags.withLock { $0.cancelled = true }
        await process.terminateGroup(grace: grace)
    }

    /// Stops the group without calling it a cancellation (stopping a service).
    @discardableResult
    public func terminate(grace: Duration = .seconds(5)) async -> Bool {
        await process.terminateGroup(grace: grace)
    }

    /// SIGKILL to the whole group.
    public func forceKill() async -> Bool {
        kill(-process.processGroupID, SIGKILL)
        return await ProcessGroup.waitUntilGone(process.processGroupID, timeout: .seconds(2))
    }

    private func makeResult(_ termination: Termination) -> RunResult {
        let flags = flags.withLock { $0 }
        let ending: RunResult.Ending
        if let limit = flags.timedOut {
            ending = .timedOut(limit)
        } else if flags.cancelled {
            ending = .cancelled
        } else {
            switch termination {
            case .exited(let code): ending = .exited(code)
            case .signaled(let signal): ending = .signaled(signal)
            }
        }
        return RunResult(
            ending: ending,
            command: output.redactor.redact(command),
            startedAt: startedAt,
            endedAt: Date(),
            result: output.result,
            reason: output.reason,
            firstErrorLine: output.firstErrorLine,
            lastLine: output.lastLine,
            output: output.text
        )
    }

    private func resolve(_ result: RunResult) {
        let pending = finished.withLock { stored -> [CheckedContinuation<RunResult, Never>] in
            stored = result
            return waiters.withLock { waiters in
                defer { waiters = [] }
                return waiters
            }
        }
        pending.forEach { $0.resume(returning: result) }
    }
}
