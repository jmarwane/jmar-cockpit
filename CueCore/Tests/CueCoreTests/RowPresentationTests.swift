@testable import CueCore
import Foundation
import Testing

/// The one-click table from spec §5.
@Suite struct RowPresentationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tested(_ item: Item) -> Item {
        var item = item
        item.testedSignature = item.signature
        return item
    }

    private var web: Item {
        tested(Item(kind: .service, name: "Splash Server", command: "npm run dev", runningWhen: .port("$PORT"), address: "localhost:$PORT")
            .with { $0.inputs = [Input(name: "PORT", defaultValue: "4000")] })
    }

    private func row(_ item: Item, _ state: ServiceState, checking: Bool = false, owns: Bool = false) -> RowPresentation {
        RowPresentation.make(item: item, service: ServiceStatus(state: state, isChecking: checking, ownsProcess: owns), now: now)
    }

    @Test func serviceRows() {
        #expect(row(web, .off(since: now.addingTimeInterval(-180))) == RowPresentation(glyph: .off, subtitle: "Not running · stopped 3m ago", primary: .start))
        #expect(row(web, .off(since: nil)).subtitle == "Not running")
        #expect(row(web, .starting(since: now)) == RowPresentation(glyph: .starting, subtitle: "Starting…", primary: .none))
        #expect(row(web, .on(since: now.addingTimeInterval(-240), origin: .cue), owns: true)
            == RowPresentation(glyph: .on, subtitle: "Running · 4m · localhost:4000", primary: .stop))
        #expect(row(web, .stopping(since: now)) == RowPresentation(glyph: .stopping, subtitle: "Stopping…", primary: .none))
        #expect(row(web, .unknown("Docker isn't responding")) == RowPresentation(glyph: .unknown, subtitle: "Status unknown · Docker isn't responding", primary: .check))
        #expect(row(web, .unknown(nil), checking: true) == RowPresentation(glyph: .checking, subtitle: "Checking status…", primary: .none))
        #expect(row(web, .on(since: nil, origin: .lastSession)).subtitle == "On · from last session")
    }

    @Test func startedOutsideCueStopsTheRightWay() {
        #expect(row(web, .on(since: nil, origin: .outside)) == RowPresentation(glyph: .on, subtitle: "On · started outside Cue", primary: .stopProcessOnPort(4000)))
        let withCommand = tested(web.with { $0.stopBy = .command("docker stop web") })
        #expect(row(withCommand, .on(since: nil, origin: .outside)).primary == .stop)
        let statusOnly = tested(web.with { $0.runningWhen = .statusCommand("pgrep -q x") })
        #expect(row(statusOnly, .on(since: nil, origin: .outside)).primary == .none)
    }

    @Test func failedRowsShowTheBestReason() {
        let exit = Failure(message: "Exited with code 1", exitCode: 1, errorLine: "Error: listen EADDRINUSE")
        #expect(row(web, .failed(exit)) == RowPresentation(glyph: .failed, subtitle: "Failed · exit 1 · Error: listen EADDRINUSE", primary: .showError))
        #expect(row(web, .failed(Failure(message: "Didn't come up in 30 s"))).subtitle == "Failed · Didn't come up in 30 s")
        #expect(row(web, .failed(Failure(message: "Exited with code 2", exitCode: 2, errorLine: "x", reportedReason: "quota exceeded"))).subtitle
            == "Failed · quota exceeded")
    }

    @Test func taskRows() {
        let task = tested(Item(kind: .task, name: "Report", command: "./report.sh"))
        func row(_ state: TaskState) -> RowPresentation { RowPresentation.make(item: task, task: state, now: now) }
        let done = RunResult(ending: .exited(0), command: "x", startedAt: now.addingTimeInterval(-130), endedAt: now.addingTimeInterval(-120), result: "saved streams.csv")

        #expect(row(.ready) == RowPresentation(glyph: .none, subtitle: "Ready", primary: .run))
        #expect(row(.running(since: now.addingTimeInterval(-42))) == RowPresentation(glyph: .starting, subtitle: "Running · 42s", primary: .showRunDetails))
        #expect(row(.done(done)) == RowPresentation(glyph: .none, subtitle: "Done · saved streams.csv · 2m ago", primary: .run))
        #expect(row(.cancelled(at: now.addingTimeInterval(-60))) == RowPresentation(glyph: .none, subtitle: "Cancelled · 1m ago", primary: .run))
        #expect(row(.failed(Failure(message: "Timed out after 2 min"))).primary == .showError)
        #expect(row(.outcomeUnknown).subtitle == "Outcome unknown · Cue quit during the run")
    }

    @Test func notYetTestedWhenIdle() {
        let task = Item(kind: .task, name: "Report", command: "./report.sh")
        #expect(RowPresentation.make(item: task, task: .ready, now: now) == RowPresentation(glyph: .none, subtitle: "Not yet tested", primary: .openEditorAtTestRun))
        // Not idle: the real state wins.
        #expect(RowPresentation.make(item: task, task: .running(since: now), now: now).primary == .showRunDetails)
        let service = web.with { $0.testedSignature = nil }
        #expect(row(service, .off(since: nil)).subtitle == "Not yet tested")
        #expect(row(service, .on(since: nil, origin: .cue), owns: true).primary == .stop)
    }

    @Test func sudoNeedsTerminal() {
        let task = Item(kind: .task, name: "Flush DNS", command: "sudo dscacheutil -flushcache")
        #expect(RowPresentation.make(item: task, task: .ready, now: now) == RowPresentation(glyph: .none, subtitle: "Needs Terminal", primary: .runInTerminal))
        let failed = RowPresentation.make(item: task, task: .failed(Failure(message: "Exited with code 1")), now: now)
        #expect(failed.primary == .showError)
        let service = Item(kind: .service, name: "Proxy", command: "sudo proxy", runningWhen: .port("80"))
        #expect(row(service, .off(since: nil)).primary == .runInTerminal)
        #expect(row(service, .on(since: nil, origin: .outside)).primary == .stopProcessOnPort(80))
    }

    @Test func checkupProblemsShowWhileIdle() {
        let task = tested(Item(kind: .task, name: "Backup", command: "./backup.sh"))
        let row = RowPresentation.make(item: task, task: .ready, problem: "Script not found: ./backup.sh", now: now)
        #expect(row == RowPresentation(glyph: .unknown, subtitle: "Needs attention · Script not found: ./backup.sh", primary: .edit))
        #expect(RowPresentation.make(item: task, task: .running(since: now), problem: "x", now: now).primary == .showRunDetails)
        #expect(RowPresentation.make(item: web, service: ServiceStatus(state: .on(since: nil, origin: .outside)), problem: "x", now: now).glyph == .on)
    }

    @Test func voiceOverLabels() {
        let running = ServiceStatus(state: .on(since: now.addingTimeInterval(-240), origin: .cue), ownsProcess: true)
        #expect(RowPresentation.accessibilityLabel(item: web, service: running, now: now) == "Splash Server, running for 4 minutes, localhost:4000. Stop.")
        let off = ServiceStatus(state: .off(since: now.addingTimeInterval(-60)))
        #expect(RowPresentation.accessibilityLabel(item: web, service: off, now: now) == "Splash Server, not running, stopped 1 minute ago. Start.")
        let failed = ServiceStatus(state: .failed(Failure(message: "Exited with code 1", exitCode: 1, errorLine: "Error: EADDRINUSE")))
        #expect(RowPresentation.accessibilityLabel(item: web, service: failed, now: now) == "Splash Server, failed, exit 1, Error: EADDRINUSE. Show Error.")
        let task = tested(Item(kind: .task, name: "Report", command: "x"))
        #expect(RowPresentation.accessibilityLabel(item: task, task: .running(since: now.addingTimeInterval(-42)), now: now) == "Report, running for 42 seconds. Show Details.")
        let done = RunResult(ending: .exited(0), command: "x", startedAt: now, endedAt: now.addingTimeInterval(-180), result: "saved a.csv")
        #expect(RowPresentation.accessibilityLabel(item: task, task: .done(done), now: now) == "Report, done, saved a.csv, 3 minutes ago. Run.")
        #expect(RowPresentation.accessibilityLabel(item: web, service: ServiceStatus(state: .starting(since: now)), now: now) == "Splash Server, starting.")
        let link = Item(kind: .link, name: "Admin", target: "http://localhost:4000/admin")
        #expect(RowPresentation.accessibilityLabel(item: link) == "Admin, link to localhost:4000/admin. Open.")
        #expect(RelativeText.spoken(3900) == "1 hour 5 minutes")
    }

    @Test func linkRows() {
        let link = Item(kind: .link, name: "Admin", target: "http://localhost:4000/admin")
        #expect(RowPresentation.make(item: link) == RowPresentation(glyph: .link, subtitle: "localhost:4000/admin", primary: .open))
        #expect(LinkTarget.url(for: "localhost:4000/admin")?.absoluteString == "http://localhost:4000/admin")
        #expect(LinkTarget.url(for: "https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(LinkTarget.url(for: "~/Music")?.path == NSHomeDirectory() + "/Music")
        #expect(LinkTarget.url(for: "/Applications/Logic Pro.app")?.isFileURL == true)
        #expect(LinkTarget.url(for: "example.com")?.absoluteString == "http://example.com")
        #expect(LinkTarget.display(NSHomeDirectory() + "/Music") == "~/Music")
    }

    @Test func relativeTimes() {
        #expect(RelativeText.ago(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(RelativeText.ago(now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(RelativeText.elapsed(since: now.addingTimeInterval(-3900), now: now) == "1h 5m")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(1200), now: now) == "20 min")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(1199.6), now: now) == "20 min")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(1140.2), now: now) == "19 min")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(3900), now: now) == "1 h 5 min")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(3599), now: now) == "1 h")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(3540), now: now) == "59 min")
        #expect(RelativeText.countdown(to: now.addingTimeInterval(86_400 * 2), now: now) == "2 days")
    }
}

extension Item {
    func with(_ change: (inout Item) -> Void) -> Item {
        var copy = self
        change(&copy)
        return copy
    }
}
