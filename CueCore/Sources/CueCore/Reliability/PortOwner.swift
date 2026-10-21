import Foundation

/// Who is listening on a port, from `/usr/sbin/lsof -nP -iTCP:<port> -sTCP:LISTEN`.
public struct PortOwner: Sendable, Equatable {
    public var command: String
    public var pid: pid_t

    public init(command: String, pid: pid_t) {
        self.command = command
        self.pid = pid
    }

    /// `node, pid 4312`
    public var description: String { "\(command), pid \(pid)" }

    public static func lookup(port: Int, timeout: Duration = .seconds(3)) async -> [PortOwner] {
        guard let process = try? ProcessGroup.spawn(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            output: .captureStdoutOnly(limit: 64 * 1024)
        ) else { return [] }
        guard await process.waitForExit(timeout: timeout) != nil else {
            await process.terminateGroup(grace: .milliseconds(300))
            return []
        }
        _ = await process.output?.waitForEnd(timeout: .milliseconds(500))
        return parse(String(decoding: process.output?.data ?? Data(), as: UTF8.self))
    }

    /// One owner per PID, in lsof's order. lsof escapes spaces in names as `\x20`.
    static func parse(_ output: String) -> [PortOwner] {
        var owners: [PortOwner] = []
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[1]) else { continue }
            let command = fields[0].replacingOccurrences(of: "\\x20", with: " ")
            if !owners.contains(where: { $0.pid == pid }) { owners.append(PortOwner(command: command, pid: pid)) }
        }
        return owners
    }
}
