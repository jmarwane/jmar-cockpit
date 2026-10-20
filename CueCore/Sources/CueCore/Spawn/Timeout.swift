import Synchronization

/// Returns `operation`'s result, or nil if `timeout` passes first.
/// The operation isn't cancelled; it keeps running until it finishes on its own.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce(continuation)
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.resume(returning: nil)
        }
        Task {
            let value = await operation()
            timer.cancel()
            once.resume(returning: value)
        }
    }
}

private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: T) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}
