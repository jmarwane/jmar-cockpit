import Darwin
import Foundation
import Synchronization

/// Reads a pipe on its own thread and keeps the last `limit` bytes.
public final class OutputCollector: Sendable {
    private struct State {
        var data = Data()
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    public let limit: Int
    private let state = Mutex(State())

    init(readingFrom fd: Int32, limit: Int) {
        self.limit = limit
        let thread = Thread { [self] in
            readUntilEnd(fd)
        }
        thread.name = "Cue output \(fd)"
        thread.start()
    }

    /// Everything kept so far.
    public var data: Data { state.withLock { $0.data } }

    /// True once the write end has been closed by every process holding it.
    public var isFinished: Bool { state.withLock { $0.finished } }

    /// Waits for end-of-file, or returns false after `timeout`.
    public func waitForEnd(timeout: Duration) async -> Bool {
        await withTimeout(timeout) { await self.waitForEnd() } != nil
    }

    /// Waits for end-of-file.
    public func waitForEnd() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func readUntilEnd(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                state.withLock { state in
                    state.data.append(contentsOf: buffer[0..<count])
                    if state.data.count > limit {
                        state.data = Data(state.data.suffix(limit))
                    }
                }
            } else if count == -1 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(fd)
        let waiters = state.withLock { state in
            state.finished = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
