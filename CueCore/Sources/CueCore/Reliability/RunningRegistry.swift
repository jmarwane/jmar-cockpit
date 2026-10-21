import Darwin
import Foundation
import Synchronization

/// running.json: every process group Cue owns, so a relaunch after a crash can find them (spec §11, §12).
public final class RunningRegistry: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case service, task }

        public var itemID: UUID
        public var kind: Kind
        public var pid: pid_t
        public var processGroupID: pid_t
        /// The kernel's start time for the PID, so a reused PID isn't mistaken for ours.
        public var startTime: Double
        public var startedAt: Date
    }

    public let fileURL: URL
    private let entries: Mutex<[Entry]>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        entries = Mutex(data.flatMap { try? Self.decoder.decode([Entry].self, from: $0) } ?? [])
    }

    public var all: [Entry] { entries.withLock { $0 } }

    public func add(itemID: UUID, kind: Entry.Kind, pid: pid_t, processGroupID: pid_t, startedAt: Date) {
        guard let startTime = ProcessStartTime.of(pid) else { return }
        let snapshot = entries.withLock { entries in
            entries.removeAll { $0.itemID == itemID && $0.kind == kind }
            entries.append(Entry(itemID: itemID, kind: kind, pid: pid, processGroupID: processGroupID, startTime: startTime, startedAt: startedAt))
            return entries
        }
        write(snapshot)
    }

    public func remove(itemID: UUID, kind: Entry.Kind) {
        let snapshot = entries.withLock { entries -> [Entry]? in
            let before = entries.count
            entries.removeAll { $0.itemID == itemID && $0.kind == kind }
            return entries.count == before ? nil : entries
        }
        if let snapshot { write(snapshot) }
    }

    /// Splits last session's entries: ones whose PID is alive with the same start time, and the rest.
    /// Keeps only the live ones in the file.
    public func recover() -> (alive: [Entry], gone: [Entry]) {
        let (alive, gone) = entries.withLock { entries -> ([Entry], [Entry]) in
            var alive: [Entry] = []
            var gone: [Entry] = []
            for entry in entries {
                if ProcessStartTime.of(entry.pid) == entry.startTime { alive.append(entry) } else { gone.append(entry) }
            }
            entries = alive
            return (alive, gone)
        }
        write(alive)
        return (alive, gone)
    }

    private func write(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Losing running.json only costs crash recovery; never block a run on it.
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum ProcessStartTime {
    /// Seconds since 1970 when `pid` started, or nil if there's no such process.
    public static func of(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}

/// A process group Cue started in an earlier session. Not Cue's child, so its exit is watched with kqueue.
public final class AdoptedProcess: Sendable {
    public let pid: pid_t
    public let processGroupID: pid_t
    private let source: DispatchSourceProcess

    public init(pid: pid_t, processGroupID: pid_t, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.processGroupID = processGroupID
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { onExit() }
        source.resume()
    }

    deinit { source.cancel() }

    public var groupIsAlive: Bool { ProcessGroup.isAlive(processGroupID) }
}
