import Foundation

/// What a command's text says about how to run it.
public enum CommandTraits {
    /// `rm -r`, `sudo`, `--force`, `git push`, `git reset --hard`: Ask before running is switched on when saved.
    public static func isRisky(_ command: String) -> Bool {
        let text = command.lowercased()
        if containsWord("sudo", in: text) || text.contains("--force") || text.contains("git push") || text.contains("git reset --hard") {
            return true
        }
        // rm with a recursive flag: -r, -R, -rf, -fr, --recursive.
        let pattern = #"(^|[\s;&|(])rm\s+(-[a-z]*r[a-z]*|--recursive)\b"#
        return command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Commands with `sudo` need a terminal for the password.
    public static func needsTerminal(_ command: String) -> Bool {
        containsWord("sudo", in: command)
    }

    static func containsWord(_ word: String, in text: String) -> Bool {
        text.range(of: #"(^|[^A-Za-z0-9_-])"# + NSRegularExpression.escapedPattern(for: word) + #"($|[^A-Za-z0-9_-])"#, options: .regularExpression) != nil
    }
}
