import Darwin
import Foundation
import Synchronization
@testable import CueCore

/// A temporary directory removed when the value is deinitialized.
final class TemporaryDirectory {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes an executable fixture script and returns its path.
    @discardableResult
    func script(_ name: String, _ body: String) throws -> String {
        let file = url.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func file(_ name: String, _ body: String) throws {
        try body.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// PIDs of the processes currently in group `pgid`, from /bin/ps.
func processIDs(inGroup pgid: pid_t) -> [pid_t] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-A", "-o", "pid=,pgid="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .compactMap { line -> pid_t? in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pid = pid_t(fields[0]), pid_t(fields[1]) == pgid else { return nil }
            return pid
        }
}

let minimalEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory()]

/// A TCP listener on 127.0.0.1, created inside a test. Connections complete in the kernel's backlog,
/// so nothing needs to accept them.
final class TestListener: @unchecked Sendable {
    private(set) var fd: Int32 = -1
    let port: Int

    /// With `listening` false the port is only reserved: no other test can take it, and connections are refused.
    init(port requested: Int = 0, listening: Bool = true) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(requested).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, !listening || listen(fd, 128) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        self.fd = fd
    }

    func stop() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    deinit { stop() }
}

private let nextPort = Mutex(Int.random(in: 20_000...40_000))

/// A port nothing listens on right now, for a fixture to bind. Ports come from below the ephemeral
/// range (49152+) that port-0 binds use, and each call gets a different one, so parallel tests don't collide.
func freePort() throws -> Int {
    for _ in 0..<200 {
        let port = nextPort.withLock { port -> Int in
            port = port >= 45_000 ? 20_000 : port + 1
            return port
        }
        if let probe = try? TestListener(port: port, listening: false) {
            probe.stop()
            return port
        }
    }
    throw POSIXError(.EADDRINUSE)
}

/// Polls `condition` every 20 ms until it's true or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Collects a supervisor's events from the moment it's created.
final class EventLog: Sendable {
    private final class Box: Sendable {
        let events = Mutex<[SupervisorEvent]>([])
    }

    private let box = Box()
    private let task: Task<Void, Never>

    init(_ supervisor: Supervisor) {
        let box = self.box
        task = Task {
            for await event in supervisor.events { box.events.withLock { $0.append(event) } }
        }
    }

    var all: [SupervisorEvent] { box.events.withLock { $0 } }

    var unexpectedExits: Int {
        all.filter { if case .unexpectedExit = $0 { true } else { false } }.count
    }

    deinit { task.cancel() }
}
