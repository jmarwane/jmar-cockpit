import Foundation

/// What a file dropped on the panel or the icon becomes (spec §6, Drops).
public enum DropAction: Sendable, Equatable {
    /// An executable script: a command with its absolute path, quoted.
    case command(String)
    /// A script with a shebang that isn't executable yet: offer Make executable, then the command.
    case needsExecutable(path: String, command: String)
    /// No shebang: run it through the interpreter its extension implies, and say so.
    case viaInterpreter(command: String, interpreter: String)
    /// A folder, an app or any other file.
    case link(String)

    public static let interpreters = ["sh": "sh", "bash": "bash", "zsh": "zsh", "py": "python3", "rb": "ruby", "js": "node", "pl": "perl"]

    public static func forFile(at path: String) -> DropAction {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .link(path)
        }
        let quoted = ShellQuote.quote(path)
        if FileManager.default.isExecutableFile(atPath: path) { return .command(quoted) }
        if hasShebang(path) { return .needsExecutable(path: path, command: quoted) }
        let ext = (path as NSString).pathExtension.lowercased()
        if let interpreter = interpreters[ext] {
            return .viaInterpreter(command: "\(interpreter) \(quoted)", interpreter: interpreter)
        }
        return .link(path)
    }

    static func hasShebang(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
    }
}

public enum ShellQuote {
    /// Single-quotes a word for sh when it needs it.
    public static func quote(_ word: String) -> String {
        let safe = word.allSatisfy { $0.isLetter || $0.isNumber || "/._-+:@%,=".contains($0) }
        if safe && !word.isEmpty { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// `cd <folder> && <command>` for Run in Terminal, with inputs as quoted assignments in front.
/// Secrets are never passed: they would land in the terminal's history.
public enum TerminalCommand {
    public static func line(for item: Item, inputs: [String: String]) -> String {
        let folder = LaunchSpec.expandFolder(item.workingDirectory)
        let assignments = item.inputs.map { "\($0.name)=\(ShellQuote.quote(inputs[$0.name] ?? $0.defaultValue))" }
        let plainEnvironment = item.environment.filter { !$0.isSecret && !$0.key.isEmpty }.map { "\($0.key)=\(ShellQuote.quote($0.value))" }
        let prefix = (plainEnvironment + assignments).map { "export \($0); " }.joined()
        return "cd \(ShellQuote.quote(folder)) && \(prefix)\(item.command)"
    }

    /// The AppleScript that opens Terminal and runs `line`.
    public static func appleScript(for line: String) -> String {
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    }
}
