@testable import CueCore
import Darwin
import Foundation
import Testing

@Suite struct RunnerTests {
    let dir: TemporaryDirectory

    init() throws { dir = try TemporaryDirectory() }

    private func launch(_ command: String, item: Item? = nil, inputs: [String: String] = [:], secrets: any SecretStore = InMemorySecretStore()) throws -> LaunchSpec {
        let item = item ?? Item(kind: .task, name: "T", command: command, workingDirectory: dir.path, shell: .sh)
        return try LaunchSpec.make(command: command, for: item, inputs: inputs, baseEnvironment: minimalEnvironment, secrets: secrets)
    }

    private func run(_ command: String, timeLimit: Duration? = nil) async throws -> RunResult {
        let handle = try await Runner().start(UUID(), launch: try launch(command), timeLimit: timeLimit)
        return await handle.result()
    }

    @Test func doneReadsTheResultLine() async throws {
        let result = try await run("echo working; echo '::cue result saved streams.csv'; pwd")
        #expect(result.ending == .exited(0))
        #expect(result.exitedZero)
        #expect(result.failureMessage == nil)
        #expect(result.result == "saved streams.csv")
        #expect(result.lastLine == String(cString: realpath(dir.path, nil)))
    }

    @Test func failureCarriesCodeErrorLineAndReason() async throws {
        let result = try await run("echo 'Error: listen EADDRINUSE' >&2; echo '::cue reason port taken'; exit 1")
        #expect(result.ending == .exited(1))
        #expect(result.failureMessage == "Exited with code 1")
        #expect(result.firstErrorLine == "Error: listen EADDRINUSE")
        #expect(result.reason == "port taken")
    }

    @Test func explainsExitCodes127And126() async throws {
        let missing = try await run("cue-no-such-command --flag")
        #expect(missing.ending == .exited(127))
        #expect(missing.failureMessage == "Command not found: cue-no-such-command")
        #expect(missing.hint == "Not on Cue's PATH; check Settings › Environment")

        let missingPath = try await run("./missing-script.sh")
        #expect(missingPath.failureMessage == "Command not found: ./missing-script.sh")
        #expect(missingPath.hint == "No program at that path; relative paths start from the item's folder")

        try dir.file("plain.txt", "not a program")
        let notExecutable = try await run("./plain.txt")
        #expect(notExecutable.ending == .exited(126))
        #expect(notExecutable.failureMessage == "Not executable")
    }

    @Test func inputsArriveAsEnvironmentAndAreNeverSpliced() async throws {
        let marker = dir.url.appendingPathComponent("pwned").path
        let item = Item(
            kind: .task, name: "T", command: "printf '%s|%s|%s' \"$NAME\" \"$CUE\" \"$PLAIN\"", workingDirectory: dir.path, shell: .sh,
            environment: [EnvironmentVariable(key: "PLAIN", value: "p")],
            inputs: [Input(name: "NAME", defaultValue: "default")]
        )
        let hostile = "x; touch \(marker); $(touch \(marker))"
        let spec = try launch(item.command, item: item, inputs: ["NAME": hostile])
        #expect(spec.command == item.command)
        let result = await (try await Runner().start(UUID(), launch: spec)).result()
        #expect(result.output == "\(hostile)|1|p")
        #expect(!FileManager.default.fileExists(atPath: marker))

        let defaulted = try launch(item.command, item: item)
        #expect(defaulted.environment["NAME"] == "default")
    }

    @Test func secretsComeFromTheStoreAndAreMasked() async throws {
        let id = UUID()
        let item = Item(id: id, kind: .task, name: "T", command: "echo \"token is $TOKEN\"; echo \"$TOKEN\" >&2; exit 2", workingDirectory: dir.path, shell: .sh,
                        environment: [EnvironmentVariable(key: "TOKEN", isSecret: true)])
        let secrets = InMemorySecretStore([id: ["TOKEN": "tok-123456"]])
        let result = await (try await Runner().start(id, launch: try launch(item.command, item: item, secrets: secrets))).result()
        #expect(result.output.contains("token is ••••"))
        #expect(!result.output.contains("tok-123456"))
        #expect(result.firstErrorLine == "••••")

        #expect(throws: LaunchError.missingSecret("TOKEN")) {
            try launch(item.command, item: item, secrets: InMemorySecretStore())
        }
    }

    @Test func missingFolderIsReportedBeforeSpawning() {
        let item = Item(kind: .task, name: "T", command: "true", workingDirectory: dir.path + "/nope")
        #expect(throws: LaunchError.folderNotFound(dir.path + "/nope")) { try launch("true", item: item) }
    }

    @Test func timeLimitStopsTheWholeGroup() async throws {
        let started = ContinuousClock.now
        let handle = try await Runner().start(UUID(), launch: try launch("sleep 30 & sleep 30; wait"), timeLimit: .milliseconds(300))
        let pgid = handle.process.processGroupID
        let result = await handle.result()
        #expect(result.ending == .timedOut(.milliseconds(300)))
        #expect(result.failureMessage == "Timed out after 0 s")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await eventually { !ProcessGroup.isAlive(pgid) })
    }

    @Test func cancelEndsTheRunAsCancelled() async throws {
        let runner = Runner()
        let id = UUID()
        let handle = try await runner.start(id, launch: try launch("sleep 30 & sleep 30; wait"))
        #expect(await runner.handle(for: id) != nil)
        await runner.cancel(id, grace: .milliseconds(500))
        let result = await handle.result()
        #expect(result.ending == .cancelled)
        #expect(!handle.groupIsAlive)
        #expect(await eventually { await runner.handle(for: id) == nil })
    }

    @Test func onlyOneActiveRunPerItem() async throws {
        let runner = Runner()
        let id = UUID()
        let first = try await runner.start(id, launch: try launch("sleep 30"))
        await #expect(throws: RunError.alreadyRunning) {
            try await runner.start(id, launch: try launch("true"))
        }
        let other = try await runner.start(UUID(), launch: try launch("true"))
        #expect(await other.result().exitedZero)
        await first.cancel(grace: .milliseconds(300))
        _ = await first.result()
        #expect(await eventually { await runner.handle(for: id) == nil })
        let again = try await runner.start(id, launch: try launch("true"))
        #expect(await again.result().exitedZero)
    }

    @Test func stdinIsAtEndOfFile() async throws {
        let result = try await run("read line && echo got || echo eof")
        #expect(result.lastLine == "eof")
    }
}
