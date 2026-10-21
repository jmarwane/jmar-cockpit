import Foundation

/// The last runs of each item, in `runs/<itemID>/` (spec §11).
public struct RunHistory: Sendable {
    public static let limit = 20

    public struct Record: Codable, Sendable, Equatable {
        public var startedAt: Date
        public var endedAt: Date
        public var exitCode: Int32?
        public var ending: String
        public var result: String?
        public var reason: String?
        public var command: String
        /// File name of the kept output next to the record, if Keep output was on.
        public var log: String?
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func folder(for itemID: UUID) -> URL {
        directory.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    /// Writes a run, with its (already redacted) output when `keepOutput`, then keeps only the newest 20.
    @discardableResult
    public func record(_ run: RunResult, itemID: UUID, keepOutput: Bool) throws -> Record {
        let folder = folder(for: itemID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.stamp(run.startedAt)
        var record = Record(
            startedAt: run.startedAt, endedAt: run.endedAt, exitCode: run.exitCode, ending: Self.describe(run.ending),
            result: run.result, reason: run.reason, command: run.command, log: nil
        )
        if keepOutput {
            let log = "\(stamp).log"
            try Data(run.output.utf8).write(to: folder.appendingPathComponent(log), options: .atomic)
            record.log = log
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appendingPathComponent("\(stamp).json"), options: .atomic)
        prune(folder)
        return record
    }

    /// Newest first.
    public func records(for itemID: UUID) -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return jsonFiles(in: folder(for: itemID)).reversed().compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Record.self, from: $0) }
        }
    }

    /// The newest kept log for an item.
    public func latestLog(for itemID: UUID) -> URL? {
        records(for: itemID).lazy.compactMap { $0.log }.first.map { folder(for: itemID).appendingPathComponent($0) }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func forget(_ itemID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: itemID))
    }

    private func prune(_ folder: URL) {
        let records = jsonFiles(in: folder)
        guard records.count > Self.limit else { return }
        for url in records.prefix(records.count - Self.limit) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("log"))
        }
    }

    /// Oldest first: the names are sortable timestamps.
    private func jsonFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS"
        return formatter.string(from: date) + "-" + UUID().uuidString.prefix(4)
    }

    static func describe(_ ending: RunResult.Ending) -> String {
        switch ending {
        case .exited(let code): "exit \(code)"
        case .signaled(let signal): "signal \(signal)"
        case .cancelled: "cancelled"
        case .timedOut(let limit): "timed out after \(DurationText.short(limit))"
        }
    }
}
