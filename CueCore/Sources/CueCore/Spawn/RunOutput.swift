import Darwin
import Foundation
import Synchronization

/// Everything a run wrote: one bounded buffer for both streams, plus the few lines Cue reads.
public final class RunOutput: Sendable {
    public enum Stream: Sendable { case stdout, stderr }

    public static let defaultLimit = 256 * 1024
    /// A line longer than this is cut, so output without newlines can't grow without bound.
    static let maxLineLength = 16 * 1024

    private struct State {
        var data = Data()
        var partial: [Stream: Data] = [:]
        var openStreams = 0
        var started = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var lastLine: String?
        var firstErrorLine: String?
        var firstStderrLine: String?
        var lastStderrLine: String?
        var result: String?
        var reason: String?
    }

    public let limit: Int
    public let redactor: Redactor
    private let state = Mutex(State())

    init(limit: Int = RunOutput.defaultLimit, redactor: Redactor = Redactor()) {
        self.limit = limit
        self.redactor = redactor
    }

    // MARK: Reading

    /// The kept bytes, unredacted. Used for parsing (environment capture), never shown.
    public var data: Data { state.withLock { $0.data } }

    /// The kept output as text, with secrets replaced by `••••`.
    public var text: String { redactor.redact(String(decoding: data, as: UTF8.self)) }

    /// The last non-empty line from either stream.
    public var lastLine: String? { state.withLock { $0.lastLine } }

    /// The first line that looks like an error, or else the last stderr line.
    public var firstErrorLine: String? { state.withLock { $0.firstErrorLine ?? $0.lastStderrLine } }

    /// The first stderr line, used as the reason when a status command can't decide.
    public var firstStderrLine: String? { state.withLock { $0.firstStderrLine } }

    public var lastStderrLine: String? { state.withLock { $0.lastStderrLine } }

    /// The text of the last `::cue result` line.
    public var result: String? { state.withLock { $0.result } }

    /// The text of the last `::cue reason` line.
    public var reason: String? { state.withLock { $0.reason } }

    public var isFinished: Bool { state.withLock { $0.started && $0.openStreams == 0 } }

    /// Waits until every captured stream reaches end-of-file.
    public func waitForEnd() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                if state.started && state.openStreams == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Waits for end-of-file, or returns false after `timeout`.
    public func waitForEnd(timeout: Duration) async -> Bool {
        await withTimeout(timeout) { await self.waitForEnd() } != nil
    }

    // MARK: Writing

    func startReading(from fd: Int32, stream: Stream) {
        state.withLock {
            $0.openStreams += 1
            $0.started = true
        }
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    append(Data(buffer[0..<count]), from: stream)
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            finish(stream)
        }
        thread.name = "Cue output \(fd)"
        thread.start()
    }

    /// Adds bytes as if `stream` had written them.
    func append(_ bytes: Data, from stream: Stream) {
        state.withLock { state in
            state.data.append(bytes)
            if state.data.count > limit {
                state.data = Data(state.data.suffix(limit))
            }
            var pending = (state.partial[stream] ?? Data()) + bytes
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                take(line: pending[pending.startIndex..<newline], from: stream, into: &state)
                pending = Data(pending[pending.index(after: newline)...])
            }
            if pending.count > Self.maxLineLength {
                take(line: pending, from: stream, into: &state)
                pending = Data()
            }
            state.partial[stream] = pending
        }
    }

    private func finish(_ stream: Stream) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if let rest = state.partial[stream], !rest.isEmpty {
                take(line: rest, from: stream, into: &state)
            }
            state.partial[stream] = nil
            state.openStreams -= 1
            guard state.openStreams == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func take(line raw: Data, from stream: Stream, into state: inout State) {
        var line = String(decoding: raw, as: UTF8.self)
        // A carriage return redraws the line (progress bars); only the last frame counts.
        if let lastReturn = line.dropLast(line.hasSuffix("\r") ? 1 : 0).lastIndex(of: "\r") {
            line = String(line[line.index(after: lastReturn)...])
        }
        line = redactor.redact(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return }

        if let text = Self.cueDirective("result", in: line) {
            state.result = text
            return
        }
        if let text = Self.cueDirective("reason", in: line) {
            state.reason = text
            return
        }

        state.lastLine = line
        if stream == .stderr {
            if state.firstStderrLine == nil { state.firstStderrLine = line }
            state.lastStderrLine = line
        }
        if state.firstErrorLine == nil, Self.looksLikeError(line) { state.firstErrorLine = line }
    }

    static let errorMarkers = ["error", "Error", "ERR!", "fatal", "Traceback"]

    static func looksLikeError(_ line: String) -> Bool {
        errorMarkers.contains { line.contains($0) }
    }

    /// The text after `::cue <name> `, if the line is that directive.
    static func cueDirective(_ name: String, in line: String) -> String? {
        let prefix = "::cue \(name) "
        guard line.hasPrefix(prefix) else { return nil }
        let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
