@testable import CueCore
import Foundation
import Testing

@Suite struct QuickAddTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// Tuesday 2026-10-20 15:00 in Paris.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15, minute: 0))!

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func classify(_ text: String, path: String = "/usr/bin:/bin") -> Classifier.Guess {
        Classifier.classify(text, path: path, now: Self.now, calendar: Self.calendar)
    }

    // MARK: The spec's table (§15, M4)

    @Test func specTable() throws {
        let dir = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try dir.script("bin/splash", "#!/bin/sh\n")
        let path = "\(dir.path)/bin:/usr/bin:/bin"

        #expect(classify("splash serve", path: path).kind == .command)
        let plants = classify("water the plants", path: path)
        #expect(plants.kind == .reminder)
        #expect(plants.reminder.due == nil)
        #expect(classify("npm test -- --watch", path: path).kind == .command)
        #expect(classify("localhost:4000/admin", path: path).kind == .link)
        let bank = classify("call the bank at 18:30", path: path)
        #expect(bank.kind == .reminder)
        #expect(bank.reminder == ReminderParser.Parsed(text: "call the bank", due: at(20, 18, 30)))
    }

    @Test func linkRules() {
        for link in ["https://example.com/a?b=1", "http://localhost:4000", "localhost", "localhost:4000/admin",
                     "127.0.0.1:8080/x", "example.com", "docs.swift.org/swift-book", "EXAMPLE.COM"] {
            #expect(classify(link).kind == .link, "\(link)")
        }
        for notLink in ["example . com", "file.txt then", "v1.2", "stretch"] {
            #expect(classify(notLink).kind != .link, "\(notLink)")
        }
    }

    @Test func shellSyntaxWins() {
        for command in ["ls | wc -l", "make && make install", "echo hi; echo there", "date > now.txt", "echo $HOME",
                        "echo `date`", "./run.sh", "~/bin/thing", "/usr/local/bin/x", "tool -x", "tool --flag",
                        "remind me at 5 > log"] {
            #expect(classify(command).kind == .command, "\(command)")
        }
        // Shell syntax comes before the time phrase.
        #expect(classify("sleep 5 && say done at 6pm").kind == .command)
    }

    @Test func programOnPathOrBuiltinIsACommand() {
        #expect(classify("ls").kind == .command)
        #expect(classify("cd projects").kind == .command)
        #expect(classify("frobnicate the widgets").kind == .reminder)
        // A time phrase beats rule 4: `open` exists, but this reads as a reminder.
        #expect(classify("open the windows in 20m").kind == .reminder)
    }

    @Test func promptsAreStripped() {
        #expect(Classifier.stripPrompt("$ npm run dev") == "npm run dev")
        #expect(Classifier.stripPrompt("  % brew update\n") == "brew update")
        #expect(Classifier.stripPrompt("$ cd x\n$ make") == "cd x\nmake")
        #expect(Classifier.stripPrompt("$HOME/bin/x") == "$HOME/bin/x")
        #expect(classify("$ ls -la").text == "ls -la")
    }

    @Test func tabCyclesTheThreeTypes() {
        #expect(Classifier.Kind.link.next == .command)
        #expect(Classifier.Kind.command.next == .reminder)
        #expect(Classifier.Kind.reminder.next == .link)
    }

    @Test func linkNames() {
        #expect(Classifier.linkName("localhost:4000/admin") == "Admin")
        #expect(Classifier.linkName("https://www.example.com/") == "example.com")
        #expect(Classifier.linkName("https://github.com/org/my-repo") == "My repo")
        #expect(Classifier.linkName("/Applications/Logic Pro.app") == "Logic Pro")
    }

    // MARK: Time phrases

    private func parse(_ text: String) -> ReminderParser.Parsed {
        ReminderParser.parse(text, now: Self.now, calendar: Self.calendar)
    }

    @Test func relativeTimes() {
        #expect(parse("stretch in 20m") == .init(text: "stretch", due: Self.now.addingTimeInterval(1200)))
        #expect(parse("tea in 2 hours").due == Self.now.addingTimeInterval(7200))
        #expect(parse("check in 1 hour").due == Self.now.addingTimeInterval(3600))
        #expect(parse("x in 45 min").due == Self.now.addingTimeInterval(2700))
        #expect(parse("x in 30s").due == Self.now.addingTimeInterval(30))
        #expect(parse("x in 2 days").due == Self.now.addingTimeInterval(172_800))
        #expect(parse("log in to the bank").due == nil)
    }

    @Test func clockTimes() {
        #expect(parse("call at 18:30") == .init(text: "call", due: at(20, 18, 30)))
        #expect(parse("call at 6pm").due == at(20, 18))
        #expect(parse("call at 6:45 pm").due == at(20, 18, 45))
        #expect(parse("call at 16h30").due == at(20, 16, 30))
        // Already past today: tomorrow.
        #expect(parse("standup at 9:30").due == at(21, 9, 30))
        #expect(parse("standup at 9am").due == at(21, 9))
        #expect(parse("lunch at 14:00").due == at(21, 14))
        // No am/pm: an hour that's passed this morning but not this evening means the evening.
        #expect(parse("dinner at 7").due == at(20, 19))
        #expect(parse("x at 25:00").due == nil)
        #expect(parse("x at 7:75").due == nil)
    }

    @Test func midnightAndNoon() {
        #expect(parse("x at 12am").due == at(21, 0))
        #expect(parse("x at 12pm").due == at(21, 12))
        #expect(parse("x at 12:30am").due == at(21, 0, 30))
        #expect(parse("x at 12:15pm").due == at(21, 12, 15))
        #expect(parse("x at 0:00").due == at(21, 0))
        #expect(parse("x at 13pm").due == nil)
        #expect(parse("x at 0am").due == nil)
    }

    @Test func tomorrow() {
        #expect(parse("dentist tomorrow") == .init(text: "dentist", due: at(21, 9)))
        #expect(parse("dentist tomorrow at 9") == .init(text: "dentist", due: at(21, 9)))
        #expect(parse("dentist tomorrow at 2pm").due == at(21, 14))
        #expect(parse("dentist tomorrow 16:15").due == at(21, 16, 15))
        #expect(parse("Tomorrow").due == at(21, 9))
    }

    // MARK: Drops and Terminal

    @Test func dropsBecomeTheRightThing() throws {
        let dir = try TemporaryDirectory()
        let executable = try dir.script("run me.sh", "#!/bin/sh\necho hi\n")
        try dir.file("plain.sh", "#!/bin/sh\necho hi\n")
        try dir.file("tool.py", "print('hi')\n")
        try dir.file("notes.txt", "hello")

        #expect(DropAction.forFile(at: executable) == .command("'\(executable)'"))
        let plain = dir.url.appendingPathComponent("plain.sh").path
        #expect(DropAction.forFile(at: plain) == .needsExecutable(path: plain, command: plain))
        let python = dir.url.appendingPathComponent("tool.py").path
        #expect(DropAction.forFile(at: python) == .viaInterpreter(command: "python3 \(python)", interpreter: "python3"))
        let notes = dir.url.appendingPathComponent("notes.txt").path
        #expect(DropAction.forFile(at: notes) == .link(notes))
        #expect(DropAction.forFile(at: dir.path) == .link(dir.path))
    }

    @Test func terminalLineAndScript() {
        let item = Item(kind: .task, name: "Deploy", command: "make deploy", workingDirectory: "/tmp/my app",
                        environment: [EnvironmentVariable(key: "STAGE", value: "prod"), EnvironmentVariable(key: "TOKEN", isSecret: true)],
                        inputs: [Input(name: "TARGET", defaultValue: "web")])
        let line = TerminalCommand.line(for: item, inputs: ["TARGET": "it's live"])
        #expect(line == "cd '/tmp/my app' && export STAGE=prod; export TARGET='it'\\''s live'; make deploy")
        #expect(!line.contains("TOKEN"))
        let script = TerminalCommand.appleScript(for: "echo \"hi\" \\ there")
        #expect(script.contains(#"do script "echo \"hi\" \\ there""#))
        #expect(ShellQuote.quote("/usr/bin/x") == "/usr/bin/x")
        #expect(ShellQuote.quote("a b") == "'a b'")
    }
}
