import Foundation

/// The launch check-up (spec §15, M6): a missing folder, a missing script, or a program that
/// can't be found marks the item as needing attention.
public enum LibraryCheckup {
    public static func problem(for item: Item, path: String) -> String? {
        guard item.runsCommands, !item.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let folder = LaunchSpec.expandFolder(item.workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Folder not found: \(item.workingDirectory)"
        }
        guard let word = ProgramResolver.programWord(of: item.command), !word.contains("$") else { return nil }
        switch ProgramResolver.resolveWord(word, path: path, folder: folder) {
        case .path, .builtin:
            return nil
        case .notFound:
            if word.contains("/") {
                let expanded = word.hasPrefix("~") ? LaunchSpec.expandFolder(word) : word
                let full = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: folder).appendingPathComponent(expanded).path
                return FileManager.default.fileExists(atPath: full) ? "Not executable: \(word)" : "Script not found: \(word)"
            }
            return "Program not found: \(word)"
        }
    }
}
