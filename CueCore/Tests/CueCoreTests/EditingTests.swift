@testable import CueCore
import Foundation
import Synchronization
import Testing

@Suite struct EditingTests {
    @Test func findsTheProgramWord() {
        #expect(ProgramResolver.programWord(of: "npm run dev") == "npm")
        #expect(ProgramResolver.programWord(of: "PORT=4000 NODE_ENV=dev exec node server.js") == "node")
        #expect(ProgramResolver.programWord(of: "# comment\n\n  ./scripts/report.sh --all") == "./scripts/report.sh")
        #expect(ProgramResolver.programWord(of: "'my tool' arg") == "my tool")
        #expect(ProgramResolver.programWord(of: "sudo -E launchctl kickstart x") == "launchctl")
        #expect(ProgramResolver.programWord(of: "cd ~/x && make") == "cd")
        #expect(ProgramResolver.programWord(of: "   ") == nil)
        #expect(ProgramResolver.isVariableName("PORT_2"))
        #expect(ProgramResolver.isVariableName("_x"))
        #expect(!ProgramResolver.isVariableName("2PORT"))
        #expect(!ProgramResolver.isVariableName("MY-PORT"))
        #expect(!ProgramResolver.isVariableName(""))
    }

    @Test func resolvesAgainstPathFolderAndBuiltins() throws {
        let dir = try TemporaryDirectory()
        let bin = dir.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = try dir.script("bin/splash", "#!/bin/sh\n")
        try dir.script("local.sh", "#!/bin/sh\n")
        try dir.file("plain.txt", "x")

        #expect(ProgramResolver.resolve("splash serve", path: "/nope:\(bin.path)", folder: dir.path) == .path(tool))
        #expect(ProgramResolver.resolve("echo hi", path: "", folder: dir.path) == .builtin("echo"))
        #expect(ProgramResolver.resolve("./local.sh", path: "", folder: dir.path) == .path(dir.url.appendingPathComponent("local.sh").path))
        #expect(ProgramResolver.resolve("./plain.txt", path: "", folder: dir.path) == .notFound("./plain.txt"))
        #expect(ProgramResolver.resolve("splash serve", path: "/usr/bin", folder: dir.path) == .notFound("splash"))
        // A directory with the program's name isn't the program.
        #expect(ProgramResolver.resolveWord("bin", path: dir.path, folder: "/") == .notFound("bin"))
    }

    @Test func riskyCommandsAskFirst() {
        for risky in ["rm -rf build", "sudo port install x", "git push --force-with-lease", "git push", "git reset --hard HEAD~1",
                      "cd x && rm -r y", "rm -fr y", "rm --recursive y", "tool --force"] {
            #expect(CommandTraits.isRisky(risky), "\(risky)")
        }
        for safe in ["rm file.txt", "npm run dev", "git pull", "pseudo-tool", "grep -r rm .", "firm -r"] {
            #expect(!CommandTraits.isRisky(safe), "\(safe)")
        }
        #expect(CommandTraits.needsTerminal("sudo launchctl list"))
        #expect(!CommandTraits.needsTerminal("pseudosudo x"))
    }

    @Test func suggestsKindNameAndIcon() {
        #expect(ItemSuggestions.kind(for: "npm run dev") == .service)
        #expect(ItemSuggestions.kind(for: "splash serve") == .service)
        #expect(ItemSuggestions.kind(for: "docker compose up -d") == .service)
        #expect(ItemSuggestions.kind(for: "npm test -- --watch") == .service)
        #expect(ItemSuggestions.kind(for: "brew update && brew upgrade") == .task)
        #expect(ItemSuggestions.kind(for: "./backup.sh") == .task)

        #expect(ItemSuggestions.name(for: "splash serve") == "Splash serve")
        #expect(ItemSuggestions.name(for: "./scripts/weekly-report.sh --all") == "Weekly report")
        #expect(ItemSuggestions.name(for: "npm run dev", folder: "~/Code/splash") == "Splash dev")
        #expect(ItemSuggestions.name(for: "npm run dev") == "Npm dev")
        #expect(ItemSuggestions.name(for: "python3 tools/export_streams.py") == "Export streams")
        #expect(ItemSuggestions.name(for: "") == "New Item")
        #expect(ItemSuggestions.name(for: "rm -rf /tmp/build") == "Rm")
        #expect(ItemSuggestions.name(for: "rsync -a ~/Music /Volumes/Backup") == "Rsync")

        #expect(ItemSuggestions.icon(for: "docker compose up", kind: .service) == "shippingbox")
        #expect(ItemSuggestions.icon(for: "npm run dev", kind: .service) == "server.rack")
        #expect(ItemSuggestions.icon(for: "./weekly-report.sh", kind: .task) == "doc.text")
        #expect(ItemSuggestions.icons.count >= 12)
        #expect(ItemSuggestions.tint(for: "Splash") == ItemSuggestions.tint(for: "Splash"))
    }

    // MARK: Test Run

    final class Steps: Sendable {
        let steps = Mutex<[TestStep]>([])
        func add(_ step: TestStep) { steps.withLock { $0.append(step) } }
        var all: [TestStep] { steps.withLock { $0 } }
        var texts: [String] { all.map(\.text) }
    }

    private func test(_ item: Item, inputs: [String: String] = [:]) async -> (Bool, Steps) {
        let steps = Steps()
        let passed = await TestRunner.run(
            item, inputs: inputs, environment: minimalEnvironment, secrets: InMemorySecretStore(),
            timing: SupervisorTests.fast, report: { steps.add($0) }
        )
        return (passed, steps)
    }

    @Test func taskTestReportsProgramFolderShellAndExit() async throws {
        let dir = try TemporaryDirectory()
        let item = Item(kind: .task, name: "Report", command: "echo \"for $WHO\"; echo '::cue result saved a.csv'",
                        workingDirectory: dir.path, shell: .sh, inputs: [Input(name: "WHO", defaultValue: "me")])
        let (passed, steps) = await test(item, inputs: ["WHO": "the team"])
        #expect(passed)
        #expect(steps.texts[0] == "WHO='the team' echo \"for $WHO\"; echo '::cue result saved a.csv'")
        #expect(steps.texts[1] == "Program echo (shell builtin)")
        #expect(steps.texts[2] == "Folder \(dir.path)")
        #expect(steps.texts[3] == "Shell sh")
        #expect(steps.texts.contains("for the team"))
        #expect(steps.all.contains { $0.kind == .success && $0.text.hasPrefix("Exited 0 after ") })
        #expect(steps.texts.contains("Result: saved a.csv"))
    }

    @Test func failingTaskTestExplains() async throws {
        let item = Item(kind: .task, name: "Broken", command: "cue-missing-tool --x", workingDirectory: NSTemporaryDirectory(), shell: .sh)
        let (passed, steps) = await test(item)
        #expect(!passed)
        #expect(steps.texts.contains("Program cue-missing-tool isn't on Cue's PATH"))
        #expect(steps.all.contains { $0.kind == .failure && $0.text.hasPrefix("Command not found: cue-missing-tool after") })
        #expect(steps.texts.contains("Not on Cue's PATH; check Settings › Environment"))
    }

    @Test func serviceTestStartsChecksAndStops() async throws {
        let port = try freePort()
        let item = Item(kind: .service, name: "Web", command: "exec /usr/bin/nc -lk 127.0.0.1 \"$PORT\"", workingDirectory: NSTemporaryDirectory(),
                        shell: .sh, inputs: [Input(name: "PORT")], runningWhen: .port("$PORT"))
        let (passed, steps) = await test(item, inputs: ["PORT": String(port)])
        #expect(passed, "\(steps.texts)")
        #expect(steps.texts.contains { $0.hasPrefix("Port \(port) answered after ") })
        #expect(steps.texts.last == "Stopped, and the check confirms it's off")
        #expect(!(await PortProbe.isAnswering(port: port)))
    }

    @Test func serviceAlreadyRunningIsNotTested() async throws {
        let listener = try TestListener()
        let item = Item(kind: .service, name: "Web", command: "sleep 30", workingDirectory: NSTemporaryDirectory(), shell: .sh,
                        runningWhen: .port(String(listener.port)))
        let (passed, steps) = await test(item)
        #expect(!passed)
        #expect(steps.texts.last == "It's already running. Stop it, then test again.")
    }

    @Test func processServiceThatExitsRightAwayFailsItsTest() async throws {
        let item = Item(kind: .service, name: "Daemon", command: "true", workingDirectory: NSTemporaryDirectory(), shell: .sh, runningWhen: .process)
        let (passed, steps) = await test(item)
        #expect(!passed)
        #expect(steps.texts.contains("Exited right away. If it starts something in the background, use a port or status check."))
    }

    @Test func processServicePassesWhenItKeepsRunning() async throws {
        let item = Item(kind: .service, name: "Daemon", command: "sleep 30", workingDirectory: NSTemporaryDirectory(), shell: .sh, runningWhen: .process)
        let (passed, steps) = await test(item)
        #expect(passed, "\(steps.texts)")
        #expect(steps.texts.contains { $0.hasPrefix("Process still running after ") })
    }
}
