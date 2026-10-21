import Darwin
import Foundation

/// What a service's check says.
public enum CheckResult: Sendable, Equatable {
    case on
    case off
    /// The check couldn't tell, with the reason when there is one.
    case unknown(String?)
}

public enum PortProbe {
    /// True if a TCP connection to 127.0.0.1 or ::1 on `port` succeeds within `timeout`.
    public static func isAnswering(port: Int, timeout: Duration = .seconds(1)) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: connects(port: port, timeout: timeout))
            }
        }
    }

    static func connects(port: Int, timeout: Duration) -> Bool {
        let sockets = [socket(AF_INET, SOCK_STREAM, 0), socket(AF_INET6, SOCK_STREAM, 0)]
        defer { sockets.filter { $0 >= 0 }.forEach { close($0) } }

        var pending: [pollfd] = []
        for (index, fd) in sockets.enumerated() where fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let result = index == 0 ? connectIPv4(fd, port: port) : connectIPv6(fd, port: port)
            if result == 0 { return true }
            if errno == EINPROGRESS { pending.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)) }
        }

        let deadline = ContinuousClock.now + timeout
        while !pending.isEmpty {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            let milliseconds = Int32(max(1, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            let ready = poll(&pending, nfds_t(pending.count), milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return false }
            var stillPending: [pollfd] = []
            for entry in pending {
                guard entry.revents != 0 else {
                    stillPending.append(pollfd(fd: entry.fd, events: entry.events, revents: 0))
                    continue
                }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 { return true }
            }
            pending = stillPending
        }
        return false
    }

    private static func connectIPv4(_ fd: Int32, port: Int) -> Int32 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    private static func connectIPv6(_ fd: Int32, port: Int) -> Int32 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }
}

public enum StatusCommand {
    /// Runs a status command and reads its exit code: 0 is On, 1 is Off, anything else is Unknown.
    public static func check(_ launch: LaunchSpec, timeout: Duration = .seconds(5)) async -> CheckResult {
        let process: SpawnedProcess
        do {
            process = try ProcessGroup.spawn(
                executable: launch.shell,
                arguments: launch.arguments,
                environment: launch.environment,
                workingDirectory: launch.workingDirectory,
                output: .capture(limit: 64 * 1024, redactor: launch.redactor)
            )
        } catch {
            return .unknown("Couldn't run the status command: \(String(cString: strerror(error.code)))")
        }
        guard let termination = await process.waitForExit(timeout: timeout) else {
            await process.terminateGroup(grace: .milliseconds(500))
            return .unknown("Status command timed out after \(DurationText.short(timeout))")
        }
        _ = await process.output?.waitForEnd(timeout: .milliseconds(500))
        let firstErrorLine = process.output?.firstStderrLine
        switch termination {
        case .exited(0): return .on
        case .exited(1): return .off
        case .exited(let code): return .unknown(firstErrorLine ?? "Status command exited with code \(code)")
        case .signaled(let signal): return .unknown(firstErrorLine ?? "Status command stopped by signal \(signal)")
        }
    }
}
