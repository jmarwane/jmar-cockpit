import Foundation

/// Why something is Failed, with what the UI's error details show.
public struct Failure: Error, Sendable, Equatable {
    /// The headline: `Exited with code 1`, `Didn't come up in 30 s`.
    public var message: String
    public var exitCode: Int32?
    /// The first error line from the output.
    public var errorLine: String?
    /// From `::cue reason`.
    public var reportedReason: String?
    public var hint: String?
    public var at: Date
    /// True when Cue still owns processes it can kill.
    public var canForceStop: Bool
    /// The run behind the failure, when there was one.
    public var run: RunResult?

    public init(
        message: String, exitCode: Int32? = nil, errorLine: String? = nil, reportedReason: String? = nil,
        hint: String? = nil, at: Date = Date(), canForceStop: Bool = false, run: RunResult? = nil
    ) {
        self.message = message
        self.exitCode = exitCode
        self.errorLine = errorLine
        self.reportedReason = reportedReason
        self.hint = hint
        self.at = at
        self.canForceStop = canForceStop
        self.run = run
    }

    init(_ message: String, run: RunResult, canForceStop: Bool = false) {
        self.init(
            message: message,
            exitCode: run.exitCode,
            errorLine: run.firstErrorLine,
            reportedReason: run.reason,
            hint: run.hint,
            at: run.endedAt,
            canForceStop: canForceStop,
            run: run
        )
    }
}

public enum ServiceState: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// Cue started it this session.
        case cue
        /// It was On before Cue launched anything.
        case outside
        /// Cue started it in an earlier session and still owns its process.
        case lastSession
    }

    /// Not checked yet, or the check couldn't tell.
    case unknown(String?)
    case off(since: Date?)
    case starting(since: Date)
    case on(since: Date?, origin: Origin)
    case stopping(since: Date)
    case failed(Failure)

    public var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }
}

public struct ServiceStatus: Sendable, Equatable {
    public var state: ServiceState
    /// A check is running; the state shown is the last result.
    public var isChecking: Bool
    public var lastCheckedAt: Date?
    /// Cue owns a live process group for this service.
    public var ownsProcess: Bool

    public init(state: ServiceState = .unknown(nil), isChecking: Bool = false, lastCheckedAt: Date? = nil, ownsProcess: Bool = false) {
        self.state = state
        self.isChecking = isChecking
        self.lastCheckedAt = lastCheckedAt
        self.ownsProcess = ownsProcess
    }
}

public enum TaskState: Sendable, Equatable {
    case ready
    case running(since: Date)
    /// Exited 0. Says nothing about whether the output is right.
    case done(RunResult)
    case failed(Failure)
    case cancelled(at: Date)
    /// Cue quit or crashed during the run.
    case outcomeUnknown

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// What a click on Stop can do for a service in its current state.
public enum StopOutcome: Sendable, Equatable {
    case stopped
    /// Already starting or stopping; nothing was done.
    case ignored
    /// Cue doesn't own a process and there's no stop command. For a port check, the port to look up.
    case notOwned(port: Int?)
}

public enum SupervisorEvent: Sendable, Equatable {
    case service(UUID, ServiceStatus)
    case task(UUID, TaskState)
    /// A service process Cue owns exited while it should have been running.
    case unexpectedExit(UUID, Failure)
    /// A task run, start command or stop command ended.
    case runFinished(UUID, RunResult)
}
