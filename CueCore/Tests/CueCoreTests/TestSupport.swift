import Foundation

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
