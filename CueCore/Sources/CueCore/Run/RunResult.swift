import Darwin
import Foundation

/// How one run of a command ended, with what Cue read from its output.
public struct RunResult: Sendable, Equatable {
    public enum Ending: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
        case cancelled
        case timedOut(Duration)
    }

    public var ending: Ending
    public var command: String
    public var startedAt: Date
    public var endedAt: Date
    /// From the last `::cue result` line.
    public var result: String?
    /// From the last `::cue reason` line.
    public var reason: String?
    public var firstErrorLine: String?
    public var lastLine: String?
    /// The kept output, with secrets masked.
    public var output: String

    public init(
        ending: Ending, command: String, startedAt: Date, endedAt: Date,
        result: String? = nil, reason: String? = nil, firstErrorLine: String? = nil,
        lastLine: String? = nil, output: String = ""
    ) {
        self.ending = ending
        self.command = command
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.result = result
        self.reason = reason
        self.firstErrorLine = firstErrorLine
        self.lastLine = lastLine
        self.output = output
    }

    /// "The command exited 0." Says nothing about whether its output is right.
    public var exitedZero: Bool { ending == .exited(0) }

    public var exitCode: Int32? {
        if case .exited(let code) = ending { return code }
        return nil
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Why the run counts as failed, or nil when it exited 0.
    public var failureMessage: String? {
        switch ending {
        case .exited(0): nil
        case .exited(127): "Command not found: \(missingCommand)"
        case .exited(126): "Not executable"
        case .exited(let code): "Exited with code \(code)"
        case .signaled(let signal): "Stopped by signal \(signal) (\(Self.signalName(signal)))"
        case .cancelled: "Cancelled"
        case .timedOut(let limit): "Timed out after \(DurationText.short(limit))"
        }
    }

    public var hint: String? {
        ending == .exited(127) ? "Not on Cue's PATH; check Settings › Environment" : nil
    }

    /// The shell's own "command not found: X" if it said so, or else the command's first word.
    var missingCommand: String {
        for line in output.split(separator: "\n").reversed() {
            if let range = line.range(of: "command not found: ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasSuffix(": command not found"), let name = line.dropLast(": command not found".count).split(separator: ":").last {
                return name.trimmingCharacters(in: .whitespaces)
            }
            if line.hasSuffix(": not found"), let name = line.dropLast(": not found".count).split(separator: ":").last {
                return name.trimmingCharacters(in: .whitespaces)
            }
        }
        return command.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? command
    }

    static func signalName(_ signal: Int32) -> String {
        guard let name = strsignal(signal) else { return "signal \(signal)" }
        return String(cString: name)
    }
}
