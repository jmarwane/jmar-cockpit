import Darwin
import Foundation

/// The state machine from spec §3. Status comes only from checks; launching something never sets On by itself.
public actor Supervisor {
    public struct Timing: Sendable {
        public var pollInterval: Duration = .milliseconds(500)
        public var startTimeout: Duration = .seconds(30)
        public var stopTimeout: Duration = .seconds(10)
        public var terminateGrace: Duration = .seconds(5)
        public var exitedRightAway: Duration = .seconds(3)
        public var portTimeout: Duration = .seconds(1)
        public var statusTimeout: Duration = .seconds(5)
        public var stopCommandTimeout: Duration = .seconds(30)

        public init() {}

        public static let standard = Timing()
    }

    /// A service's check with its placeholders filled in.
    enum ResolvedCheck: Sendable, Equatable {
        case process
        case port(Int)
        case statusCommand(String)
    }

    private struct Owned {
        let handle: RunHandle
        let launchedAt: Date
        let check: ResolvedCheck
        /// Set when Cue itself is ending the process, so its exit isn't unexpected.
        var stopping = false
    }

    public nonisolated let events: AsyncStream<SupervisorEvent>
    private let continuation: AsyncStream<SupervisorEvent>.Continuation

    private let runner: Runner
    private let secrets: any SecretStore
    private let timing: Timing
    private var environment: [String: String]

    private var items: [UUID: Item] = [:]
    private var services: [UUID: ServiceStatus] = [:]
    private var tasks: [UUID: TaskState] = [:]
    private var owned: [UUID: Owned] = [:]
    /// Inputs of the current or last start, so later checks resolve the same port.
    private var inputsInUse: [UUID: [String: String]] = [:]
    /// Bumped by every start, stop and failure, so a superseded loop drops its result.
    private var generations: [UUID: Int] = [:]

    public init(
        runner: Runner = Runner(),
        environment: [String: String],
        secrets: any SecretStore,
        timing: Timing = .standard
    ) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.runner = runner
        self.environment = environment
        self.secrets = secrets
        self.timing = timing
    }

    // MARK: Library

    public func setEnvironment(_ environment: [String: String]) {
        self.environment = environment
    }

    public func setItems(_ newItems: [Item]) {
        items = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for item in newItems {
            switch item.kind {
            case .service:
                if services[item.id] == nil { services[item.id] = ServiceStatus() }
                tasks[item.id] = nil
            case .task:
                if tasks[item.id] == nil { tasks[item.id] = .ready }
                services[item.id] = nil
            case .link:
                services[item.id] = nil
                tasks[item.id] = nil
            }
        }
        for id in Array(services.keys) where items[id] == nil { services[id] = nil }
        for id in Array(tasks.keys) where items[id] == nil { tasks[id] = nil }
    }

    public func status(of id: UUID) -> ServiceStatus? { services[id] }

    public func taskState(of id: UUID) -> TaskState? { tasks[id] }

    /// The active run of a task or the process of a service Cue owns.
    public func activeRun(of id: UUID) async -> RunHandle? {
        if let owned = owned[id], owned.handle.isActive { return owned.handle }
        return await runner.handle(for: id)
    }

    // MARK: Checks

    /// Checks a service again: Checking, then the result. Ignored while it's starting or stopping.
    public func check(_ id: UUID) async {
        guard let item = items[id], item.kind == .service, let status = services[id], !status.state.isTransitioning else { return }
        let generation = generations[id, default: 0]
        let values = inputsInUse[id] ?? item.currentInputValues
        let check: ResolvedCheck
        do {
            check = try resolveCheck(item, values)
        } catch {
            update(id) { $0.state = .unknown(error.description) }
            return
        }
        update(id) { $0.isChecking = true }
        var result = await perform(check, for: item, inputs: values)
        // Checks are retried (§9): one failed probe doesn't turn a running service Off.
        if result != .on, services[id]?.state.isOn == true {
            try? await Task.sleep(for: timing.pollInterval)
            guard generations[id, default: 0] == generation else { return }
            result = await perform(check, for: item, inputs: values)
        }
        guard generations[id, default: 0] == generation, let current = services[id], !current.state.isTransitioning else { return }
        apply(result, to: id)
    }

    private func apply(_ result: CheckResult, to id: UUID) {
        update(id) { status in
            status.isChecking = false
            status.lastCheckedAt = Date()
            switch (result, status.state) {
            case (.on, .on):
                break
            case (.on, _):
                status.state = .on(since: nil, origin: status.ownsProcess ? .cue : .outside)
            case (.off, .failed), (.unknown, .failed):
                // A failure stays until it's acted on; only a passing check replaces it.
                break
            case (.off, .off):
                break
            case (.off, .on):
                status.state = .off(since: Date())
            case (.off, _):
                status.state = .off(since: nil)
            case (.unknown(let reason), _):
                status.state = .unknown(reason)
            }
        }
    }

    func resolveCheck(_ item: Item, _ inputs: [String: String]) throws(LaunchError) -> ResolvedCheck {
        switch item.runningWhen {
        case .process:
            return .process
        case .port(let text):
            do {
                return .port(try Placeholders.port(text, values: LaunchSpec.placeholderValues(for: item, inputs: inputs)))
            } catch {
                throw .invalidPort(error)
            }
        case .statusCommand(let command):
            return .statusCommand(command)
        }
    }

    private func perform(_ check: ResolvedCheck, for item: Item, inputs: [String: String]) async -> CheckResult {
        switch check {
        case .process:
            return owned[item.id]?.handle.groupIsAlive == true ? .on : .off
        case .port(let port):
            return await PortProbe.isAnswering(port: port, timeout: timing.portTimeout) ? .on : .off
        case .statusCommand(let command):
            do {
                let launch = try LaunchSpec.make(
                    command: command, for: item, inputs: inputs, baseEnvironment: environment, secrets: secrets
                )
                return await StatusCommand.check(launch, timeout: timing.statusTimeout)
            } catch {
                return .unknown(error.description)
            }
        }
    }

    // MARK: Start

    /// Check first; if it's not already On, launch, then poll the check until it passes or time runs out.
    public func start(_ id: UUID, inputs: [String: String]? = nil) async {
        guard let item = items[id], item.kind == .service, let status = services[id] else { return }
        if status.state.isTransitioning || status.state.isOn { return }

        let values = inputs ?? item.currentInputValues
        let generation = bump(id)
        let check: ResolvedCheck
        do {
            check = try resolveCheck(item, values)
        } catch {
            fail(id, Failure(message: error.description))
            return
        }
        if case .port(let port) = check, let holder = cueService(holding: port, other: id) {
            fail(id, Failure(message: "Port \(port) is already in use by \(holder)"))
            return
        }
        inputsInUse[id] = values

        update(id) { $0.isChecking = true }
        let before = await perform(check, for: item, inputs: values)
        guard isCurrent(id, generation) else { return }
        if before == .on {
            update(id) { status in
                status.isChecking = false
                status.lastCheckedAt = Date()
                status.state = .on(since: nil, origin: status.ownsProcess ? .cue : .outside)
            }
            return
        }

        let handle: RunHandle
        do {
            let launch = try LaunchSpec.make(
                command: item.command, for: item, inputs: values, baseEnvironment: environment, secrets: secrets
            )
            handle = try await runner.start(id, launch: launch)
        } catch let error as RunError {
            fail(id, Failure(message: error.description))
            return
        } catch let error as LaunchError {
            fail(id, Failure(message: error.description))
            return
        } catch {
            fail(id, Failure(message: "\(error)"))
            return
        }
        guard isCurrent(id, generation) else {
            await handle.terminate(grace: timing.terminateGrace)
            return
        }

        let launchedAt = Date()
        owned[id] = Owned(handle: handle, launchedAt: launchedAt, check: check)
        update(id) { status in
            status.isChecking = false
            status.ownsProcess = true
            status.state = .starting(since: launchedAt)
        }
        Task {
            let result = await handle.result()
            await self.ownedRunEnded(id, handle, result)
        }

        let deadline = ContinuousClock.now + timing.startTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: timing.pollInterval)
            guard isCurrent(id, generation) else { return }
            let result = await perform(check, for: item, inputs: values)
            guard isCurrent(id, generation) else { return }
            if result == .on {
                update(id) { status in
                    status.lastCheckedAt = Date()
                    status.state = .on(since: Date(), origin: .cue)
                }
                return
            }
        }

        bump(id)
        var canForceStop = false
        if let entry = owned[id], entry.handle === handle {
            owned[id]?.stopping = true
            canForceStop = !(await handle.terminate(grace: timing.terminateGrace))
            if !canForceStop { owned[id] = nil }
        }
        update(id) { $0.ownsProcess = canForceStop }
        fail(id, Failure(message: "Didn't come up in \(DurationText.short(timing.startTimeout))", canForceStop: canForceStop))
    }

    /// The start command or service process Cue owns has exited.
    private func ownedRunEnded(_ id: UUID, _ handle: RunHandle, _ result: RunResult) async {
        continuation.yield(.runFinished(id, result))
        guard let entry = owned[id], entry.handle === handle else { return }
        if entry.stopping { return }

        let state = services[id]?.state
        let quick = result.endedAt.timeIntervalSince(entry.launchedAt) < timing.exitedRightAway.seconds

        if !handle.groupIsAlive { owned[id] = nil }
        update(id) { $0.ownsProcess = handle.groupIsAlive }

        switch entry.check {
        case .process:
            if handle.groupIsAlive { return }
            bump(id)
            if quick {
                fail(id, Failure("Exited right away. If it starts something in the background, use a port or status check.", run: result))
            } else if case .on = state {
                let failure = Failure("Exited unexpectedly · \(Self.exitText(result))", run: result)
                fail(id, failure)
                continuation.yield(.unexpectedExit(id, failure))
            } else if case .starting = state {
                fail(id, Failure(result.failureMessage ?? "Exited with code 0", run: result))
            }

        case .port, .statusCommand:
            switch state {
            case .starting:
                // Exiting 0 before the check passes is normal (`docker start`); the poll keeps going.
                guard !result.exitedZero else { return }
                bump(id)
                fail(id, Failure(result.failureMessage ?? "Exited", run: result))
            case .on:
                // Exiting 0 after handing off (`docker compose up -d`) is fine if the check still passes.
                guard let item = items[id] else { return }
                let generation = generations[id, default: 0]
                let now = await perform(entry.check, for: item, inputs: inputsInUse[id] ?? item.currentInputValues)
                guard isCurrent(id, generation) else { return }
                if now == .on { return }
                bump(id)
                let failure = Failure("Exited unexpectedly · \(Self.exitText(result))", run: result)
                fail(id, failure)
                continuation.yield(.unexpectedExit(id, failure))
            default:
                return
            }
        }
    }

    static func exitText(_ result: RunResult) -> String {
        switch result.ending {
        case .exited(let code): "exit \(code)"
        case .signaled(let signal): "signal \(signal)"
        case .cancelled: "cancelled"
        case .timedOut(let limit): "timed out after \(DurationText.short(limit))"
        }
    }

    /// The name of another service Cue is running on `port`.
    private func cueService(holding port: Int, other id: UUID) -> String? {
        for (otherID, entry) in owned where otherID != id && entry.check == .port(port) && entry.handle.groupIsAlive {
            return items[otherID]?.name ?? "another item"
        }
        return nil
    }

    // MARK: Stop

    /// Stopping → apply the stop method → check again. Off only once the check fails.
    @discardableResult
    public func stop(_ id: UUID) async -> StopOutcome {
        guard let item = items[id], item.kind == .service, let status = services[id] else { return .ignored }
        if case .stopping = status.state { return .ignored }

        let values = inputsInUse[id] ?? item.currentInputValues
        let check: ResolvedCheck
        do {
            check = try resolveCheck(item, values)
        } catch {
            fail(id, Failure(message: error.description))
            return .stopped
        }
        let entry = owned[id]
        if case .process = item.stopBy, entry?.handle.groupIsAlive != true {
            if case .port(let port) = check { return .notOwned(port: port) }
            return .notOwned(port: nil)
        }

        let generation = bump(id)
        let deadline = ContinuousClock.now + timing.stopTimeout
        update(id) { status in
            status.isChecking = false
            status.state = .stopping(since: Date())
        }

        switch item.stopBy {
        case .process:
            owned[id]?.stopping = true
            if let entry { await entry.handle.terminate(grace: timing.terminateGrace) }
        case .command(let command):
            if entry != nil { owned[id]?.stopping = true }
            let result = await runOnce(command, for: item, inputs: values, timeout: timing.stopCommandTimeout)
            guard isCurrent(id, generation) else { return .stopped }
            switch result {
            case .failure(let failure):
                bump(id)
                fail(id, failure)
                return .stopped
            case .success(let run):
                continuation.yield(.runFinished(id, run))
                if !run.exitedZero {
                    bump(id)
                    fail(id, Failure("Stop command failed · \(run.failureMessage ?? "exit")", run: run))
                    return .stopped
                }
            }
        }
        guard isCurrent(id, generation) else { return .stopped }
        if let entry, !entry.handle.groupIsAlive { owned[id] = nil }
        update(id) { $0.ownsProcess = self.owned[id]?.handle.groupIsAlive == true }

        while true {
            let result = await perform(check, for: item, inputs: values)
            guard isCurrent(id, generation) else { return .stopped }
            switch result {
            case .off:
                update(id) { status in
                    status.lastCheckedAt = Date()
                    status.state = .off(since: Date())
                }
                return .stopped
            case .unknown(let reason):
                update(id) { status in
                    status.lastCheckedAt = Date()
                    status.state = .unknown(reason)
                }
                return .stopped
            case .on:
                break
            }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: timing.pollInterval)
            guard isCurrent(id, generation) else { return .stopped }
        }

        bump(id)
        let canForceStop = owned[id]?.handle.groupIsAlive == true
        fail(id, Failure(message: Self.stillRunningMessage(check), canForceStop: canForceStop))
        return .stopped
    }

    /// SIGKILL to the group Cue owns, then check again.
    @discardableResult
    public func forceStop(_ id: UUID) async -> StopOutcome {
        guard let item = items[id], item.kind == .service else { return .ignored }
        guard let entry = owned[id], entry.handle.groupIsAlive else {
            if case .port(let port)? = try? resolveCheck(item, inputsInUse[id] ?? item.currentInputValues) {
                return .notOwned(port: port)
            }
            return .notOwned(port: nil)
        }
        let generation = bump(id)
        owned[id]?.stopping = true
        update(id) { $0.state = .stopping(since: Date()) }
        let gone = await entry.handle.forceKill()
        guard isCurrent(id, generation) else { return .stopped }
        if gone { owned[id] = nil }
        update(id) { $0.ownsProcess = !gone }
        let values = inputsInUse[id] ?? item.currentInputValues
        let result = await perform(entry.check, for: item, inputs: values)
        guard isCurrent(id, generation) else { return .stopped }
        if result == .on {
            bump(id)
            fail(id, Failure(message: Self.stillRunningMessage(entry.check), canForceStop: !gone))
        } else {
            update(id) { status in
                status.lastCheckedAt = Date()
                status.state = result == .off ? .off(since: Date()) : .unknown(nil)
            }
        }
        return .stopped
    }

    static func stillRunningMessage(_ check: ResolvedCheck) -> String {
        switch check {
        case .port(let port): "Still answering on port \(port)"
        case .statusCommand: "Status command still says it's running"
        case .process: "Still running after Stop"
        }
    }

    // MARK: Tasks

    /// Ready → Running → Done, Failed or Cancelled. Returns the run's result, or nil if it didn't start.
    @discardableResult
    public func run(_ id: UUID, inputs: [String: String]? = nil) async -> RunResult? {
        guard let item = items[id], item.kind == .task else { return nil }
        if tasks[id]?.isRunning == true { return nil }
        let values = inputs ?? item.currentInputValues

        let handle: RunHandle
        do {
            let launch = try LaunchSpec.make(
                command: item.command, for: item, inputs: values, baseEnvironment: environment, secrets: secrets
            )
            handle = try await runner.start(id, launch: launch, timeLimit: item.timeLimit.duration)
        } catch RunError.alreadyRunning {
            return nil
        } catch {
            setTask(id, .failed(Failure(message: Self.describe(error))))
            return nil
        }

        setTask(id, .running(since: handle.startedAt))
        let result = await handle.result()
        continuation.yield(.runFinished(id, result))
        switch result.ending {
        case .exited(0):
            setTask(id, .done(result))
        case .cancelled:
            setTask(id, .cancelled(at: result.endedAt))
        default:
            setTask(id, .failed(Failure(result.failureMessage ?? "Failed", run: result)))
        }
        return result
    }

    /// Cancels a running task. A click never cancels by itself; the UI asks first.
    public func cancel(_ id: UUID) async {
        await runner.cancel(id, grace: timing.terminateGrace)
    }

    // MARK: Helpers

    /// Runs a stop command to completion with a time limit.
    private func runOnce(_ command: String, for item: Item, inputs: [String: String], timeout: Duration) async -> Result<RunResult, Failure> {
        do {
            let launch = try LaunchSpec.make(command: command, for: item, inputs: inputs, baseEnvironment: environment, secrets: secrets)
            let process = try ProcessGroup.spawn(
                executable: launch.shell, arguments: launch.arguments, environment: launch.environment,
                workingDirectory: launch.workingDirectory, output: .capture(redactor: launch.redactor)
            )
            let handle = RunHandle(process: process, command: launch.command, timeLimit: timeout)
            return .success(await handle.result())
        } catch {
            return .failure(Failure(message: Self.describe(error)))
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as RunError: error.description
        case let error as LaunchError: error.description
        case let error as SpawnError: RunError.spawn(error).description
        default: "\(error)"
        }
    }

    @discardableResult
    private func bump(_ id: UUID) -> Int {
        generations[id, default: 0] += 1
        return generations[id, default: 0]
    }

    private func isCurrent(_ id: UUID, _ generation: Int) -> Bool {
        generations[id, default: 0] == generation
    }

    private func update(_ id: UUID, _ change: (inout ServiceStatus) -> Void) {
        guard var status = services[id] else { return }
        let before = status
        change(&status)
        services[id] = status
        if status != before { continuation.yield(.service(id, status)) }
    }

    private func fail(_ id: UUID, _ failure: Failure) {
        update(id) { status in
            status.isChecking = false
            status.state = .failed(failure)
        }
    }

    private func setTask(_ id: UUID, _ state: TaskState) {
        guard tasks[id] != nil || items[id]?.kind == .task else { return }
        tasks[id] = state
        continuation.yield(.task(id, state))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
