import Foundation

/// One line of a test run's report.
public struct TestStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case info, success, failure }

    public var kind: Kind
    public var text: String
    /// Monospaced lines: the command and output.
    public var isCode: Bool

    public init(_ kind: Kind, _ text: String, isCode: Bool = false) {
        self.kind = kind
        self.text = text
        self.isCode = isCode
    }
}

/// Runs an item's draft for real, because the user clicked Test Run, and reports what happened (spec §7).
/// A task passes when it exits 0. A service passes when it starts, its check passes, and it stops again.
public enum TestRunner {
    public static func run(
        _ item: Item,
        inputs: [String: String],
        environment: [String: String],
        secrets: any SecretStore,
        timing: Supervisor.Timing = .standard,
        report: @escaping @Sendable (TestStep) -> Void
    ) async -> Bool {
        report(TestStep(.info, commandLine(item, inputs: inputs), isCode: true))
        let folder = LaunchSpec.expandFolder(item.workingDirectory)
        switch ProgramResolver.resolve(item.command, path: environment["PATH"] ?? "", folder: folder) {
        case .path(let path)?: report(TestStep(.info, "Program \(path)"))
        case .builtin(let word)?: report(TestStep(.info, "Program \(word) (shell builtin)"))
        case .notFound(let word)?:
            report(TestStep(.info, word.contains("/") ? "Program \(word) doesn't exist or isn't executable" : "Program \(word) isn't on Cue's PATH"))
        case nil: break
        }
        report(TestStep(.info, "Folder \(item.workingDirectory.isEmpty ? "~" : item.workingDirectory)"))
        report(TestStep(.info, "Shell \(item.shell.rawValue)"))

        switch item.kind {
        case .task: return await runTask(item, inputs: inputs, environment: environment, secrets: secrets, report: report)
        case .service: return await runService(item, inputs: inputs, environment: environment, secrets: secrets, timing: timing, report: report)
        case .link: return true
        }
    }

    /// The command as it will run, with inputs shown as the environment they arrive in.
    public static func commandLine(_ item: Item, inputs: [String: String]) -> String {
        let assignments = item.inputs.map { input in
            let value = inputs[input.name] ?? input.defaultValue
            let quoted = value.contains(where: { $0.isWhitespace || "'\"$`\\".contains($0) }) ? "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" : value
            return "\(input.name)=\(quoted)"
        }
        return (assignments + [item.command]).joined(separator: " ")
    }

    private static func runTask(
        _ item: Item, inputs: [String: String], environment: [String: String], secrets: any SecretStore,
        report: @escaping @Sendable (TestStep) -> Void
    ) async -> Bool {
        let handle: RunHandle
        do {
            let launch = try LaunchSpec.make(command: item.command, for: item, inputs: inputs, baseEnvironment: environment, secrets: secrets)
            handle = try await Runner().start(item.id, launch: launch, timeLimit: item.timeLimit.duration)
        } catch {
            report(TestStep(.failure, Supervisor.describe(error)))
            return false
        }
        let result = await handle.result()
        let duration = String(format: "%.1f s", result.duration)
        if let last = result.lastLine { report(TestStep(.info, last, isCode: true)) }
        if result.exitedZero {
            report(TestStep(.success, "Exited 0 after \(duration)"))
            if let value = result.result { report(TestStep(.info, "Result: \(value)")) }
            return true
        }
        report(TestStep(.failure, "\(result.failureMessage ?? "Failed") after \(duration)"))
        if let line = result.firstErrorLine, line != result.lastLine { report(TestStep(.failure, line, isCode: true)) }
        if let reason = result.reason { report(TestStep(.failure, "Reported by the script: \(reason)")) }
        if let hint = result.hint { report(TestStep(.info, hint)) }
        return false
    }

    private static func runService(
        _ item: Item, inputs: [String: String], environment: [String: String], secrets: any SecretStore,
        timing: Supervisor.Timing, report: @escaping @Sendable (TestStep) -> Void
    ) async -> Bool {
        let supervisor = Supervisor(environment: environment, secrets: secrets, timing: timing)
        await supervisor.setItems([item])

        await supervisor.check(item.id)
        switch await supervisor.status(of: item.id)?.state {
        case .on?:
            report(TestStep(.failure, "It's already running. Stop it, then test again."))
            return false
        case .unknown(let reason?)?:
            report(TestStep(.info, "Check before starting: unknown · \(reason)"))
        default:
            break
        }

        let started = ContinuousClock.now
        await supervisor.start(item.id, inputs: inputs)
        var state = await supervisor.status(of: item.id)?.state
        guard case .on? = state else {
            reportFailure(state, report: report)
            return false
        }
        if case .process = item.runningWhen {
            // The process check fails a start that exits within the first seconds; wait that out.
            try? await Task.sleep(for: timing.exitedRightAway)
            state = await supervisor.status(of: item.id)?.state
            guard case .on? = state else {
                reportFailure(state, report: report)
                return false
            }
        }
        let elapsed = String(format: "%.1f s", (ContinuousClock.now - started).seconds)
        report(TestStep(.success, upMessage(item, inputs: inputs, elapsed: elapsed)))

        await supervisor.stop(item.id)
        state = await supervisor.status(of: item.id)?.state
        if case .off? = state {
            report(TestStep(.success, "Stopped, and the check confirms it's off"))
            return true
        }
        reportFailure(state, report: report, stopping: true)
        await supervisor.forceStop(item.id)
        return false
    }

    private static func upMessage(_ item: Item, inputs: [String: String], elapsed: String) -> String {
        switch item.runningWhen {
        case .port(let text):
            let port = (try? Placeholders.port(text, values: LaunchSpec.placeholderValues(for: item, inputs: inputs))).map(String.init) ?? text
            return "Port \(port) answered after \(elapsed)"
        case .statusCommand: return "Status command said it's running after \(elapsed)"
        case .process: return "Process still running after \(elapsed)"
        }
    }

    private static func reportFailure(_ state: ServiceState?, report: @Sendable (TestStep) -> Void, stopping: Bool = false) {
        switch state {
        case .failed(let failure)?:
            report(TestStep(.failure, failure.message))
            if let line = failure.errorLine { report(TestStep(.failure, line, isCode: true)) }
            if let reason = failure.reportedReason { report(TestStep(.failure, "Reported by the script: \(reason)")) }
            if let hint = failure.hint { report(TestStep(.info, hint)) }
        case .unknown(let reason)?:
            report(TestStep(.failure, "Status unknown" + (reason.map { " · \($0)" } ?? "")))
        case .on?:
            report(TestStep(.failure, stopping ? "Still running after Stop" : "Still running"))
        default:
            report(TestStep(.failure, stopping ? "Couldn't confirm it stopped" : "Didn't start"))
        }
    }
}
