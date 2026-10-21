@testable import CueCore
import Darwin
import Foundation
import Testing

/// Every transition from spec §3, with fixture commands, in-test listeners and short timings.
@Suite struct SupervisorTests {
    let dir: TemporaryDirectory

    static let fast: Supervisor.Timing = {
        var timing = Supervisor.Timing()
        timing.pollInterval = .milliseconds(50)
        timing.startTimeout = .seconds(3)
        timing.stopTimeout = .seconds(1)
        timing.terminateGrace = .milliseconds(500)
        timing.exitedRightAway = .milliseconds(500)
        timing.portTimeout = .milliseconds(200)
        timing.statusTimeout = .seconds(3)
        timing.stopCommandTimeout = .seconds(2)
        return timing
    }()

    init() throws { dir = try TemporaryDirectory() }

    private func service(_ command: String, _ check: RunningWhen, stop: StopBy = .process, name: String = "Web") -> Item {
        Item(kind: .service, name: name, command: command, workingDirectory: dir.path, shell: .sh, runningWhen: check, stopBy: stop)
    }

    private func supervisor(_ items: Item..., timing: Supervisor.Timing = SupervisorTests.fast) async -> Supervisor {
        let supervisor = Supervisor(environment: minimalEnvironment, secrets: InMemorySecretStore(), timing: timing)
        await supervisor.setItems(items)
        return supervisor
    }

    private func state(_ supervisor: Supervisor, _ item: Item) async -> ServiceState? {
        await supervisor.status(of: item.id)?.state
    }

    private func failure(_ supervisor: Supervisor, _ item: Item) async -> Failure? {
        if case .failed(let failure)? = await state(supervisor, item) { return failure }
        return nil
    }

    private var flag: String { dir.url.appendingPathComponent("on").path }

    // MARK: Start

    @Test func portServiceStartsThenStops() async throws {
        let port = try freePort()
        let item = service("exec /usr/bin/nc -lk 127.0.0.1 \(port)", .port(String(port)))
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)
        guard case .on(let since, .cue)? = await state(supervisor, item) else {
            Issue.record("expected On, got \(String(describing: await state(supervisor, item)))")
            return
        }
        #expect(since != nil)
        #expect(await supervisor.status(of: item.id)?.ownsProcess == true)
        let pgid = try #require(await supervisor.activeRun(of: item.id)).process.processGroupID

        #expect(await supervisor.stop(item.id) == .stopped)
        guard case .off(let stoppedAt)? = await state(supervisor, item) else {
            Issue.record("expected Off, got \(String(describing: await state(supervisor, item)))")
            return
        }
        #expect(stoppedAt != nil)
        #expect(!ProcessGroup.isAlive(pgid))
        #expect(!(await PortProbe.isAnswering(port: port)))
    }

    @Test func passesThroughStartingBeforeOn() async throws {
        let port = try freePort()
        let item = service("sleep 0.4; exec /usr/bin/nc -lk 127.0.0.1 \(port)", .port(String(port)))
        let supervisor = await supervisor(item)
        let seen = Task {
            var states: [String] = []
            for await event in supervisor.events {
                guard case .service(_, let status) = event else { continue }
                switch status.state {
                case .starting: if states.last != "starting" { states.append("starting") }
                case .on: states.append("on"); return states
                case .failed: states.append("failed"); return states
                default: continue
                }
            }
            return states
        }
        await supervisor.start(item.id)
        #expect(await seen.value == ["starting", "on"])
        await supervisor.stop(item.id)
    }

    @Test func alreadyOnIsNotLaunchedAgain() async throws {
        let listener = try TestListener()
        let marker = dir.url.appendingPathComponent("launched").path
        let item = service("touch \(marker); sleep 30", .port(String(listener.port)))
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)

        #expect(await state(supervisor, item) == .on(since: nil, origin: .outside))
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(await supervisor.status(of: item.id)?.ownsProcess == false)
        // Cue doesn't own it and there's no stop command: the UI has to offer the port lookup.
        #expect(await supervisor.stop(item.id) == .notOwned(port: listener.port))
        #expect(await state(supervisor, item) == .on(since: nil, origin: .outside))
    }

    @Test func didntComeUpFailsAndStopsWhatItLaunched() async throws {
        let item = service("sleep 30", .port(String(try freePort())))
        let supervisor = await supervisor(item)
        let started = ContinuousClock.now

        await supervisor.start(item.id)

        #expect(ContinuousClock.now - started < .seconds(5))
        let failure = try #require(await failure(supervisor, item))
        #expect(failure.message == "Didn't come up in 3 s")
        #expect(await supervisor.activeRun(of: item.id) == nil)
        #expect(await supervisor.status(of: item.id)?.ownsProcess == false)
    }

    @Test func startCommandFailingIsReportedWithItsError() async throws {
        let item = service("echo 'Error: listen EADDRINUSE :::4000' >&2; exit 1", .port(String(try freePort())))
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)

        let failure = try #require(await failure(supervisor, item))
        #expect(failure.message == "Exited with code 1")
        #expect(failure.exitCode == 1)
        #expect(failure.errorLine == "Error: listen EADDRINUSE :::4000")
    }

    @Test func startCommandExitingZeroKeepsPollingUntilTheCheckPasses() async throws {
        // Like `docker start`: the command returns at once and the service comes up a little later.
        let item = service(
            "(sleep 0.3; touch \(flag)) >/dev/null 2>&1 &",
            .statusCommand("[ -f \(flag) ] && exit 0 || exit 1"),
            stop: .command("rm -f \(flag)")
        )
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)
        #expect(await state(supervisor, item)?.isOn == true)

        #expect(await supervisor.stop(item.id) == .stopped)
        guard case .off? = await state(supervisor, item) else {
            Issue.record("expected Off, got \(String(describing: await state(supervisor, item)))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: flag))
    }

    @Test func processCheckGoesOnAndStopsTheWholeTree() async throws {
        let item = service("sleep 30 & sleep 30; wait", .process)
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)
        #expect(await state(supervisor, item)?.isOn == true)
        let run = try #require(await supervisor.activeRun(of: item.id))
        let pgid = run.process.processGroupID
        #expect(await eventually { processIDs(inGroup: pgid).count == 3 })

        await supervisor.stop(item.id)
        guard case .off? = await state(supervisor, item) else {
            Issue.record("expected Off, got \(String(describing: await state(supervisor, item)))")
            return
        }
        #expect(processIDs(inGroup: pgid).isEmpty)
    }

    @Test func processCheckExitingRightAwayExplainsWhy() async throws {
        let item = service("echo started in background", .process)
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)

        #expect(await eventually { await failure(supervisor, item) != nil })
        #expect(await failure(supervisor, item)?.message
            == "Exited right away. If it starts something in the background, use a port or status check.")
    }

    @Test func unexpectedExitFailsAndIsReportedOnce() async throws {
        let item = service("sleep 0.8; echo 'fatal: lost connection' >&2; exit 3", .process)
        let supervisor = await supervisor(item)
        let log = EventLog(supervisor)

        await supervisor.start(item.id)
        #expect(await state(supervisor, item)?.isOn == true)

        #expect(await eventually { await failure(supervisor, item) != nil })
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.unexpectedExits == 1)
        let reported = try #require(await failure(supervisor, item))
        #expect(reported.message == "Exited unexpectedly · exit 3")
        #expect(reported.errorLine == "fatal: lost connection")
    }

    @Test func portServiceWhoseProcessExitsWhileStillAnsweringStaysOn() async throws {
        // `docker compose up -d` style: the command hands off and exits 0 after the port is up.
        let port = try freePort()
        let item = service("sleep 0.8", .port(String(port)))
        let supervisor = await supervisor(item)

        let starting = Task { await supervisor.start(item.id) }
        #expect(await eventually { if case .starting? = await state(supervisor, item) { true } else { false } })
        let listener = try TestListener(port: port)
        await starting.value
        #expect(await state(supervisor, item)?.isOn == true)

        #expect(await eventually { await supervisor.activeRun(of: item.id) == nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await state(supervisor, item)?.isOn == true)
        #expect(await supervisor.status(of: item.id)?.ownsProcess == false)
        listener.stop()
    }

    @Test func portServiceWhoseProcessExitsAndPortClosesFails() async throws {
        let port = try freePort()
        let item = service("/usr/bin/nc -lk 127.0.0.1 \(port) & sleep 0.8; kill $!; exit 0", .port(String(port)))
        let supervisor = await supervisor(item)

        await supervisor.start(item.id)
        #expect(await state(supervisor, item)?.isOn == true)

        #expect(await eventually { await failure(supervisor, item) != nil })
        #expect(await failure(supervisor, item)?.message == "Exited unexpectedly · exit 0")
    }

    // MARK: Stop

    @Test func stopThatLeavesThePortAnsweringFails() async throws {
        let listener = try TestListener()
        let port = listener.port
        listener.stop()
        let item = service("sleep 30", .port(String(port)))
        let supervisor = await supervisor(item)

        let starting = Task { await supervisor.start(item.id) }
        #expect(await eventually { if case .starting? = await state(supervisor, item) { true } else { false } })
        let other = try TestListener(port: port)
        await starting.value
        #expect(await state(supervisor, item)?.isOn == true)

        await supervisor.stop(item.id)

        let failure = try #require(await failure(supervisor, item))
        #expect(failure.message == "Still answering on port \(port)")
        #expect(!failure.canForceStop)
        other.stop()
    }

    @Test func forceStopKillsAProcessThatIgnoresTerm() async throws {
        let item = service("trap '' TERM; sleep 30 & sleep 30; wait", .process)
        var timing = Self.fast
        timing.terminateGrace = .seconds(30)
        timing.stopTimeout = .milliseconds(300)
        let supervisor = await supervisor(item, timing: timing)

        await supervisor.start(item.id)
        let pgid = try #require(await supervisor.activeRun(of: item.id)).process.processGroupID
        let stopping = Task { await supervisor.stop(item.id) }
        #expect(await eventually { if case .stopping? = await state(supervisor, item) { true } else { false } })

        await supervisor.forceStop(item.id)
        guard case .off? = await state(supervisor, item) else {
            Issue.record("expected Off, got \(String(describing: await state(supervisor, item)))")
            return
        }
        #expect(!ProcessGroup.isAlive(pgid))
        _ = await stopping.value
        guard case .off? = await state(supervisor, item) else {
            Issue.record("the superseded stop changed the state")
            return
        }
    }

    @Test func failingStopCommandIsReported() async throws {
        try FileManager.default.createFile(atPath: flag, contents: nil)
        let item = service("true", .statusCommand("[ -f \(flag) ]"), stop: .command("echo 'Error: permission denied' >&2; exit 4"))
        let supervisor = await supervisor(item)
        await supervisor.check(item.id)
        #expect(await state(supervisor, item) == .on(since: nil, origin: .outside))

        await supervisor.stop(item.id)

        let failure = try #require(await failure(supervisor, item))
        #expect(failure.message == "Stop command failed · Exited with code 4")
        #expect(failure.errorLine == "Error: permission denied")
    }

    // MARK: Checks and Unknown

    @Test func unknownStatusCommandShowsItsReasonAndRecovers() async throws {
        let mode = dir.url.appendingPathComponent("mode").path
        try "2".write(toFile: mode, atomically: true, encoding: .utf8)
        let item = service("true", .statusCommand("m=$(cat \(mode)); [ \"$m\" = 2 ] && echo \"Docker isn't responding\" >&2; exit $m"))
        let supervisor = await supervisor(item)
        #expect(await state(supervisor, item) == .unknown(nil))

        await supervisor.check(item.id)
        #expect(await state(supervisor, item) == .unknown("Docker isn't responding"))
        #expect(await supervisor.status(of: item.id)?.isChecking == false)
        #expect(await supervisor.status(of: item.id)?.lastCheckedAt != nil)

        try "0".write(toFile: mode, atomically: true, encoding: .utf8)
        await supervisor.check(item.id)
        let recovered = await state(supervisor, item)
        #expect(recovered == .on(since: nil, origin: .outside), "\(String(describing: recovered))")

        try "1".write(toFile: mode, atomically: true, encoding: .utf8)
        await supervisor.check(item.id)
        guard case .off(let since?)? = await state(supervisor, item) else {
            Issue.record("expected Off with a time after being On")
            return
        }
        #expect(since.timeIntervalSinceNow > -5)
    }

    @Test func oneFailedProbeDoesntTurnOnIntoOff() async throws {
        // The status command fails exactly once (the first time `count` reaches 2).
        let count = dir.url.appendingPathComponent("count").path
        let item = service("true", .statusCommand("n=$(cat \(count) 2>/dev/null || echo 0); n=$((n+1)); echo $n > \(count); [ $n -ne 2 ]"))
        let supervisor = await supervisor(item)
        await supervisor.check(item.id)
        #expect(await state(supervisor, item)?.isOn == true)
        await supervisor.check(item.id)
        #expect(await state(supervisor, item)?.isOn == true)
        #expect(try String(contentsOfFile: count, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "3")
    }

    @Test func checkingFlagIsSetWhileTheCheckRuns() async throws {
        let item = service("true", .statusCommand("sleep 0.3; exit 1"))
        let supervisor = await supervisor(item)
        let checking = Task { await supervisor.check(item.id) }
        #expect(await eventually { await supervisor.status(of: item.id)?.isChecking == true })
        await checking.value
        #expect(await supervisor.status(of: item.id) == ServiceStatus(state: .off(since: nil), lastCheckedAt: await supervisor.status(of: item.id)?.lastCheckedAt))
    }

    @Test func failureSurvivesAnOffCheckButNotAnOnCheck() async throws {
        let item = service("exit 1", .statusCommand("[ -f \(flag) ]"))
        let supervisor = await supervisor(item)
        await supervisor.start(item.id)
        #expect(await failure(supervisor, item) != nil)

        await supervisor.check(item.id)
        #expect(await failure(supervisor, item) != nil)

        try FileManager.default.createFile(atPath: flag, contents: nil)
        await supervisor.check(item.id)
        #expect(await state(supervisor, item) == .on(since: nil, origin: .outside))
    }

    @Test func processCheckOnlySeesWhatCueStarted() async throws {
        let item = service("sleep 30", .process)
        let supervisor = await supervisor(item)
        await supervisor.check(item.id)
        #expect(await state(supervisor, item) == .off(since: nil))
    }

    @Test func invalidPortFailsWithoutLaunching() async throws {
        var item = service("touch \(flag)", .port("$PORT"))
        item.inputs = [Input(name: "PORT", defaultValue: "")]
        let supervisor = await supervisor(item)
        await supervisor.start(item.id, inputs: ["PORT": "99999"])
        #expect(await failure(supervisor, item)?.message == "Port 99999 isn't a number from 1 to 65535")
        #expect(!FileManager.default.fileExists(atPath: flag))
    }

    @Test func inputsResolveThePort() async throws {
        let port = try freePort()
        var item = service("exec /usr/bin/nc -lk 127.0.0.1 \"$PORT\"", .port("$PORT"))
        item.inputs = [Input(name: "PORT", defaultValue: "1")]
        let supervisor = await supervisor(item)
        await supervisor.start(item.id, inputs: ["PORT": String(port)])
        let started = await state(supervisor, item)
        #expect(started?.isOn == true, "\(String(describing: started))")
        await supervisor.check(item.id)
        #expect(await state(supervisor, item)?.isOn == true)
        await supervisor.stop(item.id)
    }

    // MARK: Duplicates

    @Test func twoServicesCantShareAPortCueIsRunning() async throws {
        let port = try freePort()
        let first = service("exec /usr/bin/nc -lk 127.0.0.1 \(port)", .port(String(port)), name: "Splash Server")
        let second = service("touch \(flag); sleep 30", .port(String(port)), name: "Other")
        let supervisor = await supervisor(first, second)

        await supervisor.start(first.id)
        #expect(await state(supervisor, first)?.isOn == true)
        await supervisor.start(second.id)

        #expect(await failure(supervisor, second)?.message == "Port \(port) is already in use by Splash Server")
        #expect(!FileManager.default.fileExists(atPath: flag))
        await supervisor.stop(first.id)
    }

    @Test func startWhileOnOrStartingIsIgnored() async throws {
        let item = service("sleep 30", .process)
        let supervisor = await supervisor(item)
        await supervisor.start(item.id)
        let run = try #require(await supervisor.activeRun(of: item.id))
        await supervisor.start(item.id)
        #expect(await supervisor.activeRun(of: item.id) === run)
        await supervisor.stop(item.id)
    }

    // MARK: Tasks

    private func task(_ command: String, limit: TimeLimit = .none) -> Item {
        Item(kind: .task, name: "Report", command: command, workingDirectory: dir.path, shell: .sh, timeLimit: limit)
    }

    @Test func taskGoesReadyRunningDone() async throws {
        let item = task("sleep 0.2; echo '::cue result saved streams.csv'")
        let supervisor = await supervisor(item)
        #expect(await supervisor.taskState(of: item.id) == .ready)

        let running = Task { await supervisor.run(item.id) }
        #expect(await eventually { await supervisor.taskState(of: item.id)?.isRunning == true })
        let result = try #require(await running.value)

        #expect(await supervisor.taskState(of: item.id) == .done(result))
        #expect(result.result == "saved streams.csv")
    }

    @Test func taskFailureKeepsTheReason() async throws {
        let item = task("echo '::cue reason API quota exceeded'; exit 2")
        let supervisor = await supervisor(item)
        await supervisor.run(item.id)
        guard case .failed(let failure)? = await supervisor.taskState(of: item.id) else {
            Issue.record("expected Failed")
            return
        }
        #expect(failure.message == "Exited with code 2")
        #expect(failure.reportedReason == "API quota exceeded")
    }

    @Test func taskCancelIsCancelledNotFailed() async throws {
        let item = task("sleep 30 & sleep 30; wait")
        let supervisor = await supervisor(item)
        let running = Task { await supervisor.run(item.id) }
        #expect(await eventually { await supervisor.taskState(of: item.id)?.isRunning == true })
        let pgid = try #require(await supervisor.activeRun(of: item.id)).process.processGroupID
        await supervisor.cancel(item.id)
        _ = await running.value
        guard case .cancelled? = await supervisor.taskState(of: item.id) else {
            Issue.record("expected Cancelled, got \(String(describing: await supervisor.taskState(of: item.id)))")
            return
        }
        #expect(!ProcessGroup.isAlive(pgid))
    }

    @Test func taskTimeLimitFails() async throws {
        let item = task("sleep 30", limit: .seconds(1))
        let supervisor = await supervisor(item)
        await supervisor.run(item.id)
        guard case .failed(let failure)? = await supervisor.taskState(of: item.id) else {
            Issue.record("expected Failed")
            return
        }
        #expect(failure.message == "Timed out after 1 s")
    }

    @Test func taskRunWhileRunningIsIgnored() async throws {
        let item = task("sleep 0.5")
        let supervisor = await supervisor(item)
        let first = Task { await supervisor.run(item.id) }
        #expect(await eventually { await supervisor.taskState(of: item.id)?.isRunning == true })
        #expect(await supervisor.run(item.id) == nil)
        #expect(await first.value?.exitedZero == true)
    }

    @Test func taskThatCantLaunchFails() async throws {
        var item = task("true")
        item.workingDirectory = dir.path + "/missing"
        let supervisor = await supervisor(item)
        await supervisor.run(item.id)
        guard case .failed(let failure)? = await supervisor.taskState(of: item.id) else {
            Issue.record("expected Failed")
            return
        }
        #expect(failure.message == "Folder not found: \(dir.path)/missing")
    }
}
