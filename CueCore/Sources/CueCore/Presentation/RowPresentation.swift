import Foundation

/// The state glyph a row shows at rest (spec §14).
public enum Glyph: Sendable, Equatable {
    case none
    case off
    case starting
    case on
    case stopping
    case failed
    case unknown
    case checking
    case link
    case bell
    case fired
    case chevron
    case plus
}

/// What one click on a row does (spec §5, "What one click does").
public enum PrimaryAction: Sendable, Equatable {
    case start
    case stop
    /// Observed, not owned, no stop command: look up the port's owner and confirm first.
    case stopProcessOnPort(Int)
    case run
    case showError
    case showRunDetails
    case check
    case openEditorAtTestRun
    /// `sudo` needs a password prompt, so it runs in Terminal instead.
    case runInTerminal
    /// The launch check-up found a problem (missing folder, script or program): fix it in the editor.
    case edit
    case open
    /// Starting, Stopping, Checking: the click is ignored.
    case none

    /// The footer's label for the action.
    public var label: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .stopProcessOnPort: "Stop Process…"
        case .run: "Run"
        case .showError: "Show Error"
        case .showRunDetails: "Show Details"
        case .check: "Check Status"
        case .openEditorAtTestRun: "Test Run…"
        case .runInTerminal: "Run in Terminal"
        case .edit: "Edit…"
        case .open: "Open"
        case .none: ""
        }
    }

    /// The SF Symbol the accessory shows while the row is selected or hovered.
    public var symbol: String? {
        switch self {
        case .start, .run: "play.fill"
        case .stop, .stopProcessOnPort: "stop.fill"
        case .showError: "exclamationmark.bubble"
        case .showRunDetails: "ellipsis"
        case .check: "arrow.clockwise"
        case .openEditorAtTestRun: "hammer"
        case .runInTerminal: "apple.terminal"
        case .edit: "pencil"
        case .open: "arrow.up.right"
        case .none: nil
        }
    }
}

/// A row's glyph, subtitle and click, derived only from the item and its observed status.
public struct RowPresentation: Sendable, Equatable {
    public var glyph: Glyph
    public var subtitle: String
    public var subtitleIsMonospaced: Bool
    public var primary: PrimaryAction

    public init(glyph: Glyph, subtitle: String, subtitleIsMonospaced: Bool = false, primary: PrimaryAction) {
        self.glyph = glyph
        self.subtitle = subtitle
        self.subtitleIsMonospaced = subtitleIsMonospaced
        self.primary = primary
    }

    /// `problem` is what the launch check-up found; it shows while the item is idle.
    public static func make(item: Item, service: ServiceStatus? = nil, task: TaskState? = nil, problem: String? = nil, now: Date = Date()) -> RowPresentation {
        switch item.kind {
        case .link:
            return RowPresentation(glyph: .link, subtitle: LinkTarget.display(item.target), primary: .open)
        case .service:
            let status = service ?? ServiceStatus()
            if let problem, Self.isIdle(status.state) { return needsAttention(problem) }
            return serviceRow(item, status, now: now)
        case .task:
            let state = task ?? .ready
            if let problem, Self.isIdle(state) { return needsAttention(problem) }
            return taskRow(item, state, now: now)
        }
    }

    static func isIdle(_ state: ServiceState) -> Bool {
        switch state {
        case .off, .unknown(nil): true
        default: false
        }
    }

    static func isIdle(_ state: TaskState) -> Bool {
        switch state {
        case .ready, .done, .cancelled: true
        default: false
        }
    }

    private static func needsAttention(_ problem: String) -> RowPresentation {
        RowPresentation(glyph: .unknown, subtitle: "Needs attention · \(problem)", primary: .edit)
    }

    private static func serviceRow(_ item: Item, _ status: ServiceStatus, now: Date) -> RowPresentation {
        let address = item.address.map { Placeholders.substitute($0, values: LaunchSpec.placeholderValues(for: item, inputs: item.currentInputValues)) }

        if status.isChecking, case .unknown = status.state {
            return RowPresentation(glyph: .checking, subtitle: "Checking status…", primary: .none)
        }
        switch status.state {
        case .off(let since):
            if CommandTraits.needsTerminal(item.command) { return needsTerminal }
            if !item.isTested { return notTested }
            let subtitle = since.map { "Not running · stopped \(RelativeText.ago($0, now: now))" } ?? "Not running"
            return RowPresentation(glyph: .off, subtitle: subtitle, primary: .start)
        case .starting:
            return RowPresentation(glyph: .starting, subtitle: "Starting…", primary: .none)
        case .on(let since, let origin):
            switch origin {
            case .cue:
                var parts = ["Running"]
                if let since { parts.append(RelativeText.elapsed(since: since, now: now)) }
                if let address, !address.isEmpty { parts.append(address) }
                return RowPresentation(glyph: .on, subtitle: parts.joined(separator: " · "), primary: .stop)
            case .lastSession:
                return RowPresentation(glyph: .on, subtitle: "On · from last session", primary: .stop)
            case .outside:
                return RowPresentation(glyph: .on, subtitle: "On · started outside Cue", primary: outsideStop(item, status))
            }
        case .stopping:
            return RowPresentation(glyph: .stopping, subtitle: "Stopping…", primary: .none)
        case .failed(let failure):
            return RowPresentation(glyph: .failed, subtitle: failedSubtitle(failure), primary: .showError)
        case .unknown(let reason):
            if reason == nil, CommandTraits.needsTerminal(item.command) { return needsTerminal }
            let subtitle = reason.map { "Status unknown · \($0)" } ?? "Status unknown"
            return RowPresentation(glyph: .unknown, subtitle: subtitle, primary: .check)
        }
    }

    /// Its stop command if it has one; for a port check, the port lookup; otherwise nothing Cue can do.
    private static func outsideStop(_ item: Item, _ status: ServiceStatus) -> PrimaryAction {
        if status.ownsProcess { return .stop }
        if case .command = item.stopBy { return .stop }
        if case .port(let text) = item.runningWhen,
           let port = try? Placeholders.port(text, values: LaunchSpec.placeholderValues(for: item, inputs: item.currentInputValues)) {
            return .stopProcessOnPort(port)
        }
        return .none
    }

    private static func taskRow(_ item: Item, _ state: TaskState, now: Date) -> RowPresentation {
        let idle: Bool = switch state {
        case .ready, .done, .cancelled: true
        default: false
        }
        if idle, CommandTraits.needsTerminal(item.command) { return needsTerminal }
        switch state {
        case .ready:
            return item.isTested ? RowPresentation(glyph: .none, subtitle: "Ready", primary: .run) : notTested
        case .running(let since):
            return RowPresentation(glyph: .starting, subtitle: "Running · \(RelativeText.elapsed(since: since, now: now))", primary: .showRunDetails)
        case .done(let run):
            if !item.isTested { return notTested }
            var parts = ["Done"]
            if let result = run.result { parts.append(result) }
            parts.append(RelativeText.ago(run.endedAt, now: now))
            return RowPresentation(glyph: .none, subtitle: parts.joined(separator: " · "), primary: .run)
        case .failed(let failure):
            return RowPresentation(glyph: .failed, subtitle: failedSubtitle(failure), primary: .showError)
        case .cancelled(let at):
            if !item.isTested { return notTested }
            return RowPresentation(glyph: .none, subtitle: "Cancelled · \(RelativeText.ago(at, now: now))", primary: .run)
        case .outcomeUnknown:
            return RowPresentation(glyph: .unknown, subtitle: "Outcome unknown · Cue quit during the run", primary: .run)
        }
    }

    private static let notTested = RowPresentation(glyph: .none, subtitle: "Not yet tested", primary: .openEditorAtTestRun)
    private static let needsTerminal = RowPresentation(glyph: .none, subtitle: "Needs Terminal", primary: .runInTerminal)

    /// `Failed · <script's reason>`, `Failed · exit 1 · <first error line>`, or `Failed · <message>`.
    public static func failedSubtitle(_ failure: Failure) -> String {
        if let reason = failure.reportedReason { return "Failed · \(reason)" }
        if let code = failure.exitCode, code != 0, let line = failure.errorLine {
            return "Failed · exit \(code) · \(line)"
        }
        return "Failed · \(failure.message)"
    }
}

extension RowPresentation {
    /// What VoiceOver reads for a row: `Splash Server, running for 4 minutes, localhost:4000. Stop.`
    public static func accessibilityLabel(
        item: Item, service: ServiceStatus? = nil, task: TaskState? = nil, problem: String? = nil, now: Date = Date()
    ) -> String {
        let row = make(item: item, service: service, task: task, problem: problem, now: now)
        var status = spokenStatus(item: item, row: row, service: service, task: task, now: now)
        if status.hasSuffix("…") { status.removeLast() }
        var label = "\(item.name), \(status)."
        if row.primary != .none {
            label += " \(row.primary.label.replacingOccurrences(of: "…", with: ""))."
        }
        return label
    }

    private static func spokenStatus(item: Item, row: RowPresentation, service: ServiceStatus?, task: TaskState?, now: Date) -> String {
        switch (item.kind, service?.state, task) {
        case (.service, .on(let since?, .cue)?, _):
            var text = "running for \(RelativeText.spoken(now.timeIntervalSince(since)))"
            let address = row.subtitle.split(separator: " · ").dropFirst(2).joined(separator: ", ")
            if !address.isEmpty { text += ", \(address)" }
            return text
        case (.service, .off(let since?)?, _) where row.glyph == .off:
            return "not running, stopped \(RelativeText.spoken(now.timeIntervalSince(since))) ago"
        case (.task, _, .running(let since)?):
            return "running for \(RelativeText.spoken(now.timeIntervalSince(since)))"
        case (.link, _, _):
            return "link to \(row.subtitle)"
        default:
            // Subtitles read well once the dots become pauses and short units are spelled out.
            var text = row.subtitle.replacingOccurrences(of: " · ", with: ", ")
            text = text.replacingOccurrences(of: #"(\d+)m ago"#, with: "$1 minutes ago", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(\d+)h ago"#, with: "$1 hours ago", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(\d+)d ago"#, with: "$1 days ago", options: .regularExpression)
            guard let first = text.first else { return text }
            return first.lowercased() + text.dropFirst()
        }
    }
}

public enum RelativeText {
    /// `42 seconds`, `4 minutes`, `1 hour 5 minutes`, for VoiceOver.
    public static func spoken(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if seconds < 60 { return unit(seconds, "second") }
        if seconds < 3600 { return unit(seconds / 60, "minute") }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? unit(seconds / 3600, "hour") : "\(unit(seconds / 3600, "hour")) \(unit(minutes, "minute"))"
    }

    /// `just now`, `3m ago`, `2h ago`, `4d ago`.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// `12 min`, `1 h 5 min`, `2 days`, for reminders.
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded()))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 {
            return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        }
        let days = seconds / 86_400
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// `42s`, `4m`, `1h 5m`.
    public static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        default:
            let minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
        }
    }
}

public enum LinkTarget {
    /// What `open` gets for a link's target: a web URL, or a file URL for a path.
    public static func url(for target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: LaunchSpec.expandFolder(trimmed))
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty, !isHostWithPort(trimmed) {
            return url
        }
        return URL(string: "http://\(trimmed)")
    }

    /// The target without its scheme, and with the home folder as `~`.
    public static func display(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where trimmed.lowercased().hasPrefix(scheme) {
            let rest = String(trimmed.dropFirst(scheme.count))
            return rest.hasSuffix("/") ? String(rest.dropLast()) : rest
        }
        let home = NSHomeDirectory()
        if trimmed.hasPrefix(home + "/") { return "~" + trimmed.dropFirst(home.count) }
        return trimmed
    }

    /// `localhost:4000` parses as scheme "localhost"; treat host:port as an address instead.
    private static func isHostWithPort(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let afterColon = text[text.index(after: colon)...]
        return afterColon.first?.isNumber == true
    }
}
