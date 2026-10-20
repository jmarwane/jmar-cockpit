@testable import CueCore
import Darwin
import Foundation
import Testing

@Suite struct ProcessGroupTests {
    /// Spawns `script` with sh and waits until the group has `count` members.
    private func spawnTree(_ script: String, expecting count: Int) async throws -> SpawnedProcess {
        let process = try ProcessGroup.spawn(
            executable: "/bin/sh", arguments: ["-c", script], environment: minimalEnvironment
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while processIDs(inGroup: process.processGroupID).count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return process
    }

    @Test func stoppingTheGroupLeavesNoSurvivors() async throws {
        let process = try await spawnTree("sleep 60 & sleep 60; wait", expecting: 3)
        let members = processIDs(inGroup: process.processGroupID)
        #expect(members.count == 3, "sh plus two sleeps should share the group")
        #expect(process.groupIsAlive)

        let gone = await process.terminateGroup(grace: .seconds(5))

        #expect(gone)
        #expect(!process.groupIsAlive)
        #expect(processIDs(inGroup: process.processGroupID).isEmpty)
        for pid in members {
            #expect(kill(pid, 0) == -1 && errno == ESRCH, "pid \(pid) survived")
        }
        #expect(await process.waitForExit() == .signaled(SIGTERM))
    }

    @Test func escalatesToSigkillWhenTermIsIgnored() async throws {
        // `trap "" TERM` is inherited, so neither sh nor the sleeps react to SIGTERM.
        let process = try await spawnTree("trap '' TERM; sleep 60 & sleep 60; wait", expecting: 3)
        let members = processIDs(inGroup: process.processGroupID)
        #expect(members.count == 3)

        let started = ContinuousClock.now
        let gone = await process.terminateGroup(grace: .milliseconds(300))

        #expect(gone)
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(processIDs(inGroup: process.processGroupID).isEmpty)
        #expect(await process.waitForExit() == .signaled(SIGKILL))
    }

    @Test func runsInItsOwnGroupWithStdinAtEndOfFile() async throws {
        let dir = try TemporaryDirectory()
        // `read` fails at end-of-file instead of hanging.
        let process = try ProcessGroup.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "pwd; ps -o pgid= -p $$; if read line; then echo got; else echo eof; fi; echo oops >&2; exit 3"],
            environment: minimalEnvironment,
            workingDirectory: dir.path
        )
        let termination = await process.waitForExit(timeout: .seconds(5))
        #expect(termination == .exited(3))
        #expect(await process.output?.waitForEnd(timeout: .seconds(2)) == true)

        let lines = String(decoding: process.output?.data ?? Data(), as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let resolved = String(cString: realpath(dir.path, nil))
        #expect(lines == [resolved, "\(process.pid)", "eof", "oops"])
    }

    @Test func outputKeepsOnlyTheTail() async throws {
        let process = try ProcessGroup.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done"],
            environment: minimalEnvironment,
            outputLimit: 100
        )
        _ = await process.waitForExit(timeout: .seconds(5))
        #expect(await process.output?.waitForEnd(timeout: .seconds(2)) == true)
        let text = String(decoding: process.output?.data ?? Data(), as: UTF8.self)
        #expect(process.output?.data.count == 100)
        #expect(text.hasSuffix("line1999\n"))
    }

    @Test func reportsAMissingExecutable() {
        #expect(throws: SpawnError.self) {
            try ProcessGroup.spawn(executable: "/nonexistent/cue-test", arguments: [], environment: [:])
        }
    }
}
