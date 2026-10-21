@testable import CueCore
import Darwin
import Foundation
import Testing

@Suite struct ReliabilityTests {
    let dir: TemporaryDirectory

    init() throws { dir = try TemporaryDirectory() }

    private func service(_ command: String, _ check: RunningWhen, address: String? = nil, name: String = "Web") -> Item {
        Item(kind: .service, name: name, command: command, workingDirectory: dir.path, shell: .sh, runningWhen: check, address: address)
    }

    private func supervisor(_ items: [Item], registry: RunningRegistry? = nil) async -> Supervisor {
        let supervisor = Supervisor(environment: minimalEnvironment, secrets: InMemorySecretStore(), timing: SupervisorTests.fast, registry: registry)
        await supervisor.setItems(items)
        return supervisor
    }

    private var registryURL: URL { dir.url.appendingPathComponent("running.json") }

    // MARK: Port owners

    @Test func parsesLsofOutput() {
        let output = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node       4312 me   23u  IPv6 0x1234      0t0  TCP *:4000 (LISTEN)
        node       4312 me   24u  IPv4 0x5678      0t0  TCP *:4000 (LISTEN)
        Google\\x20  901 me   10u  IPv4 0x9abc      0t0  TCP 127.0.0.1:4000 (LISTEN)
        """
        #expect(PortOwner.parse(output) == [PortOwner(command: "node", pid: 4312), PortOwner(command: "Google ", pid: 901)])
        #expect(PortOwner(command: "node", pid: 4312).description == "node, pid 4312")
        #expect(PortOwner.parse("").isEmpty)
    }

    @Test func looksUpTheOwnerOfARealPort() async throws {
        let listener = try TestListener()
        let owners = await PortOwner.lookup(port: listener.port)
        #expect(owners.map(\.pid) == [getpid()])
    }

    @Test func addressPortConflictNamesTheOwner() async throws {
        let listener = try TestListener()
        let marker = dir.url.appendingPathComponent("launched").path
        let item = service("touch \(marker); sleep 30", .process, address: "http://localhost:\(listener.port)/admin")
        let supervisor = await supervisor([item])
        await supervisor.start(item.id)
        guard case .failed(let failure)? = await supervisor.status(of: item.id)?.state else {
            Issue.record("expected Failed")
            return
        }
        #expect(failure.message.hasPrefix("Port \(listener.port) is already in use by "))
        #expect(failure.message.hasSuffix("(pid \(getpid()))"))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func stopsAProcessOnAPortByPID() async throws {
        let port = try freePort()
        // A listener Cue didn't start: its own process group, spawned by the test.
        let outside = try ProcessGroup.spawn(executable: "/usr/bin/nc", arguments: ["-lk", "127.0.0.1", String(port)],
                                             environment: minimalEnvironment, output: .discard)
        defer { kill(-outside.processGroupID, SIGKILL) }
        #expect(await eventually { await PortProbe.isAnswering(port: port) })

        let item = service("true", .port(String(port)))
        let supervisor = await supervisor([item])
        // nc -lk briefly stops listening between connections; give the first check a few tries.
        #expect(await eventually {
            await supervisor.check(item.id)
            return await supervisor.status(of: item.id)?.state == .on(since: nil, origin: .outside)
        })
        #expect(await supervisor.stop(item.id) == .notOwned(port: port))

        let owner = try #require(await PortOwner.lookup(port: port).first)
        #expect(owner.pid == outside.pid)
        await supervisor.stopProcess(item.id, pid: owner.pid)
        guard case .off? = await supervisor.status(of: item.id)?.state else {
            Issue.record("expected Off, got \(String(describing: await supervisor.status(of: item.id)?.state))")
            return
        }
        #expect(await outside.waitForExit(timeout: .seconds(2)) != nil)
    }

    // MARK: running.json and relaunch

    @Test func registryTracksOwnedProcessesAndRecoversLiveOnes() async throws {
        let item = service("sleep 30", .process)
        let registry = RunningRegistry(fileURL: registryURL)
        let first = await supervisor([item], registry: registry)
        await first.start(item.id)
        let pgid = try #require(await first.activeRun(of: item.id)).process.processGroupID
        #expect(registry.all.map(\.itemID) == [item.id])
        #expect(FileManager.default.fileExists(atPath: registryURL.path))

        // "Relaunch": a fresh supervisor reading the same file. The first one is simply forgotten, like a crash.
        let reread = RunningRegistry(fileURL: registryURL)
        let second = await supervisor([item], registry: reread)
        await second.recover()
        let status = try #require(await second.status(of: item.id))
        guard case .on(_, .lastSession) = status.state else {
            Issue.record("expected On · from last session, got \(status.state)")
            return
        }
        #expect(status.ownsProcess)
        await second.check(item.id)
        #expect(await second.status(of: item.id)?.state.isOn == true)

        #expect(await second.stop(item.id) == .stopped)
        guard case .off? = await second.status(of: item.id)?.state else {
            Issue.record("expected Off")
            return
        }
        #expect(!ProcessGroup.isAlive(pgid))
        #expect(reread.all.isEmpty)
    }

    @Test func adoptedProcessThatDiesIsReported() async throws {
        let item = service("sleep 30", .process)
        let registry = RunningRegistry(fileURL: registryURL)
        let first = await supervisor([item], registry: registry)
        await first.start(item.id)
        let pgid = try #require(await first.activeRun(of: item.id)).process.processGroupID

        let second = await supervisor([item], registry: RunningRegistry(fileURL: registryURL))
        let log = EventLog(second)
        await second.recover()
        kill(-pgid, SIGKILL)
        #expect(await eventually {
            if case .failed(let failure)? = await second.status(of: item.id)?.state { return failure.message == "Exited unexpectedly" }
            return false
        })
        #expect(await eventually { log.unexpectedExits == 1 })
    }

    @Test func goneOrReusedEntriesAreDroppedAndTasksReadOutcomeUnknown() async throws {
        let task = Item(kind: .task, name: "Report", command: "true", workingDirectory: dir.path)
        let web = service("sleep 30", .process)
        let entries: [RunningRegistry.Entry] = [
            // A PID that's alive (this test process) but with another start time: a reused PID, not ours.
            .init(itemID: web.id, kind: .service, pid: getpid(), processGroupID: getpgrp(), startTime: 1, startedAt: Date()),
            .init(itemID: task.id, kind: .task, pid: 999_999, processGroupID: 999_999, startTime: 1, startedAt: Date()),
        ]
        try RunningRegistry.encoder.encode(entries).write(to: registryURL)
        let registry = RunningRegistry(fileURL: registryURL)
        let supervisor = await supervisor([task, web], registry: registry)
        await supervisor.recover()
        #expect(await supervisor.taskState(of: task.id) == .outcomeUnknown)
        #expect(await supervisor.status(of: web.id)?.ownsProcess == false)
        #expect(registry.all.isEmpty)
        #expect(ProcessStartTime.of(getpid()) != nil)
        #expect(ProcessStartTime.of(999_999) == nil)
    }

    @Test func runningTasksAreRegisteredUntilTheyEnd() async throws {
        let task = Item(kind: .task, name: "Report", command: "sleep 0.5", workingDirectory: dir.path)
        let registry = RunningRegistry(fileURL: registryURL)
        let supervisor = await supervisor([task], registry: registry)
        let running = Task { await supervisor.run(task.id) }
        #expect(await eventually { registry.all.contains { $0.itemID == task.id && $0.kind == .task } })
        _ = await running.value
        #expect(registry.all.isEmpty)
    }

    @Test func quitStopsOnlyWhatCueOwns() async throws {
        let item = service("sleep 30", .process)
        let task = Item(kind: .task, name: "Long", command: "sleep 30", workingDirectory: dir.path)
        let registry = RunningRegistry(fileURL: registryURL)
        let supervisor = await supervisor([item, task], registry: registry)
        await supervisor.start(item.id)
        let running = Task { await supervisor.run(task.id) }
        #expect(await eventually { await supervisor.taskState(of: task.id)?.isRunning == true })
        let owned = await supervisor.ownedRunning()
        #expect(owned.services == [item.id] && owned.tasks == [task.id])
        await supervisor.stopEverythingOwned()
        _ = await running.value
        let after = await supervisor.ownedRunning()
        #expect(after.services.isEmpty && after.tasks.isEmpty)
        #expect(registry.all.isEmpty)
    }

    // MARK: History

    @Test func historyKeepsTheLast20Runs() throws {
        let history = RunHistory(directory: dir.url.appendingPathComponent("runs"))
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<25 {
            let run = RunResult(ending: .exited(index == 24 ? 1 : 0), command: "x", startedAt: start.addingTimeInterval(Double(index)),
                                endedAt: start.addingTimeInterval(Double(index) + 0.5), result: "r\(index)", output: "out \(index)\n")
            try history.record(run, itemID: id, keepOutput: index % 2 == 0)
        }
        let records = history.records(for: id)
        #expect(records.count == 20)
        #expect(records.first?.result == "r24")
        #expect(records.first?.exitCode == 1)
        #expect(records.last?.result == "r5")
        let logs = try FileManager.default.contentsOfDirectory(atPath: history.folder(for: id).path).filter { $0.hasSuffix(".log") }
        #expect(logs.count == 10)
        let latest = try #require(history.latestLog(for: id))
        #expect(try String(contentsOf: latest, encoding: .utf8) == "out 24\n")

        try history.clear()
        #expect(history.records(for: id).isEmpty)
    }

    // MARK: Check-up

    @Test func checkupFindsMissingFoldersScriptsAndPrograms() throws {
        try dir.script("ok.sh", "#!/bin/sh\n")
        try dir.file("plain.sh", "#!/bin/sh\n")
        func problem(_ command: String, folder: String? = nil) -> String? {
            LibraryCheckup.problem(for: Item(kind: .task, name: "T", command: command, workingDirectory: folder ?? dir.path), path: "/usr/bin:/bin")
        }
        #expect(problem("./ok.sh") == nil)
        #expect(problem("ls -la") == nil)
        #expect(problem("echo hi") == nil)
        #expect(problem("$TOOL run") == nil)
        #expect(problem("./missing.sh") == "Script not found: ./missing.sh")
        #expect(problem("./plain.sh") == "Not executable: ./plain.sh")
        #expect(problem("splash serve") == "Program not found: splash")
        #expect(problem("ls", folder: dir.path + "/gone") == "Folder not found: \(dir.path)/gone")
        #expect(LibraryCheckup.problem(for: Item(kind: .link, name: "L", target: "x"), path: "") == nil)
    }
}
