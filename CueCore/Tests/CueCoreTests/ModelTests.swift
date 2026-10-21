@testable import CueCore
import Foundation
import Testing

@Suite struct ModelTests {
    @Test func storeRoundTripsAndKeepsABackup() throws {
        let dir = try TemporaryDirectory()
        let store = LibraryStore(directory: dir.url)
        #expect(try store.load() == Library())

        let service = Item(
            kind: .service, name: "Splash Server", tint: .plum, command: "npm run dev",
            workingDirectory: "~/Code/splash",
            environment: [EnvironmentVariable(key: "PORT", value: "4000"), EnvironmentVariable(key: "TOKEN", value: "s3cret", isSecret: true)],
            inputs: [Input(name: "PORT", defaultValue: "4000")],
            runningWhen: .port("$PORT"), stopBy: .command("docker stop web"), address: "localhost:$PORT"
        )
        let link = Item(kind: .link, name: "Admin", order: 1, target: "http://localhost:4000/admin")
        let reminder = Reminder(text: "Stretch", due: Date(timeIntervalSince1970: 1_800_000_000))
        let first = Library(items: [service, link], reminders: [reminder])
        try store.save(first)
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))

        var second = first
        second.items[0].name = "Renamed"
        try store.save(second)

        let loaded = try store.load()
        #expect(loaded.items[0].name == "Renamed")
        #expect(loaded.items[0].runningWhen == .port("$PORT"))
        #expect(loaded.items[0].stopBy == .command("docker stop web"))
        #expect(loaded.items[1].target == "http://localhost:4000/admin")
        #expect(loaded.reminders == [reminder])
        let backup = try LibraryStore.decoder.decode(Library.self, from: Data(contentsOf: store.backupURL))
        #expect(backup.items[0].name == "Splash Server")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func secretValuesAreNeverWritten() throws {
        let dir = try TemporaryDirectory()
        let store = LibraryStore(directory: dir.url)
        var variable = EnvironmentVariable(key: "TOKEN", isSecret: true)
        variable.value = "s3cret-value"
        let item = Item(kind: .task, name: "Deploy", command: "deploy", environment: [variable])
        try store.save(Library(items: [item]))
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!json.contains("s3cret-value"))
        #expect(json.contains("\"isSecret\" : true"))
    }

    @Test func handWrittenItemsDecodeWithDefaults() throws {
        let json = """
        {"items": [
          {"kind": "service", "name": "Web", "command": "npm run dev", "runningWhen": {"port": 4000}},
          {"kind": "task", "name": "Report", "command": "./report.sh", "timeLimit": 120},
          {"kind": "link", "name": "Docs", "target": "~/Docs"}
        ]}
        """
        let library = try LibraryStore.decoder.decode(Library.self, from: Data(json.utf8))
        #expect(library.schemaVersion == 1)
        #expect(library.items[0].runningWhen == .port("4000"))
        #expect(library.items[0].stopBy == .process)
        #expect(library.items[0].workingDirectory == "~")
        #expect(library.items[0].shell == .zsh)
        #expect(library.items[0].icon == "server.rack")
        #expect(library.items[1].timeLimit == .seconds(120))
        #expect(library.items[1].keepOutput)
        #expect(library.items[2].target == "~/Docs")
    }

    @Test func refusesNewerOrBrokenFilesInsteadOfStartingEmpty() throws {
        let dir = try TemporaryDirectory()
        let store = LibraryStore(directory: dir.url)
        try dir.file("items.json", #"{"schemaVersion": 99, "items": []}"#)
        #expect(throws: LibraryStore.LoadError.newerSchema(99)) { try store.load() }
        try dir.file("items.json", #"{"items": [{"kind": "rocket", "name": "x"}]}"#)
        #expect(throws: LibraryStore.LoadError.self) { try store.load() }
    }

    @Test func signatureTracksBehaviorNotAppearance() {
        var item = Item(kind: .task, name: "Report", command: "./report.sh")
        let original = item.signature
        #expect(!item.isTested)
        item.testedSignature = original
        #expect(item.isTested)

        item.name = "Weekly report"
        item.tint = .rose
        item.icon = "doc"
        item.order = 5
        item.lastInputs = ["X": "1"]
        #expect(item.signature == original)

        item.command = "./report.sh --all"
        #expect(item.signature != original)
        #expect(!item.isTested)

        var secret = Item(kind: .task, name: "S", command: "x", environment: [EnvironmentVariable(key: "K", isSecret: true)])
        let withKey = secret.signature
        secret.environment[0].key = "OTHER"
        #expect(secret.signature != withKey)

        #expect(Item(kind: .link, name: "L", target: "https://example.com").isTested)
    }

    @Test func placeholdersFillPortsAndAddresses() throws {
        #expect(Placeholders.substitute("localhost:$PORT/x", values: ["PORT": "4000"]) == "localhost:4000/x")
        #expect(Placeholders.substitute("${HOST}:${PORT}", values: ["HOST": "a", "PORT": "1"]) == "a:1")
        #expect(Placeholders.substitute("$MISSING and $", values: [:]) == "$MISSING and $")
        #expect(try Placeholders.port("$PORT", values: ["PORT": "8080"]) == 8080)
        #expect(throws: Placeholders.InvalidPort.self) { try Placeholders.port("$PORT", values: [:]) }
        #expect(throws: Placeholders.InvalidPort.self) { try Placeholders.port("70000", values: [:]) }
        #expect(throws: Placeholders.InvalidPort.self) { try Placeholders.port("0", values: [:]) }
    }

    @Test func durationsReadShort() {
        #expect(DurationText.short(.seconds(30)) == "30 s")
        #expect(DurationText.short(.seconds(120)) == "2 min")
        #expect(DurationText.short(.seconds(90)) == "1 min 30 s")
        #expect(DurationText.short(.seconds(3600)) == "1 h")
        #expect(DurationText.short(.milliseconds(1400)) == "1 s")
    }

    @Test func itemsKeepTheUsersOrder() {
        let a = Item(kind: .task, name: "A", order: 2)
        let b = Item(kind: .task, name: "B", order: 0)
        let c = Item(kind: .task, name: "C", order: 2)
        #expect(Library(items: [a, b, c]).orderedItems.map(\.name) == ["B", "A", "C"])
    }
}
