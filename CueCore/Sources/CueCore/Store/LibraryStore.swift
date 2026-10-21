import Darwin
import Foundation

/// Reads and writes items.json in Cue's Application Support folder.
public struct LibraryStore: Sendable {
    public enum LoadError: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case newerSchema(Int)

        public var description: String {
            switch self {
            case .unreadable(let detail): "items.json couldn't be read: \(detail)"
            case .newerSchema(let version): "items.json was written by a newer Cue (schema \(version))"
            }
        }
    }

    public let directory: URL

    public init(directory: URL = LibraryStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cue", isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent("items.json") }
    public var backupURL: URL { directory.appendingPathComponent("items.json.bak") }

    /// The saved library, or an empty one if there's no file yet.
    /// Throws rather than returning empty for a file it can't read, so a save never overwrites it.
    public func load() throws(LoadError) -> Library {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Library()
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        let library: Library
        do {
            library = try Self.decoder.decode(Library.self, from: data)
        } catch {
            throw .unreadable(Self.describe(error))
        }
        guard library.schemaVersion <= Library.currentSchemaVersion else {
            throw .newerSchema(library.schemaVersion)
        }
        return library
    }

    /// Writes to a temporary file, copies the current file to items.json.bak, then renames into place.
    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var library = library
        library.schemaVersion = Library.currentSchemaVersion
        let data = try Self.encoder.encode(library)

        let temporary = directory.appendingPathComponent(".items.json.\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
             .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}
