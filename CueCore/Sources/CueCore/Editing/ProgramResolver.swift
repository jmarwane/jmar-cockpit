import Foundation

/// Finds the program a command runs, the way the shell will: builtins, paths, then the captured PATH.
public enum ProgramResolver {
    public enum Resolution: Sendable, Equatable {
        case path(String)
        case builtin(String)
        case notFound(String)
    }

    public static let builtins: Set<String> = [
        "cd", "echo", "export", "source", ".", "eval", "set", "unset", "alias", "type", "test", "[",
        "true", "false", "printf", "read", "wait", "kill", "trap", "exit", "return", "pwd",
        "pushd", "popd", "ulimit", "umask", "builtin", "shift", "local", "let", "if", "for", "while",
        "until", "case", "function", "{", "(", "!", "[[",
    ]

    /// Words that run the next word as the program.
    static let wrappers: Set<String> = ["exec", "command", "nohup", "env", "time", "sudo", "caffeinate"]

    /// The word naming the program: first line, after `FOO=bar` assignments and wrappers like `exec`.
    public static func programWord(of command: String) -> String? {
        let firstLine = command.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard let firstLine else { return nil }
        let words = ShellWords.split(String(firstLine))
        var index = 0
        while index < words.count {
            let word = words[index]
            if isAssignment(word) || wrappers.contains(word) || (word.hasPrefix("-") && index > 0 && wrappers.contains(words[index - 1])) {
                index += 1
                continue
            }
            return word
        }
        return nil
    }

    public static func resolve(_ command: String, path: String, folder: String) -> Resolution? {
        guard let word = programWord(of: command) else { return nil }
        return resolveWord(word, path: path, folder: folder)
    }

    public static func resolveWord(_ word: String, path: String, folder: String) -> Resolution {
        if builtins.contains(word) { return .builtin(word) }
        if word.contains("/") {
            let expanded = word.hasPrefix("~") ? LaunchSpec.expandFolder(word) : word
            let full = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: folder).appendingPathComponent(expanded).standardizedFileURL.path
            return FileManager.default.isExecutableFile(atPath: full) ? .path(full) : .notFound(word)
        }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(word)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return .path(candidate)
            }
        }
        return .notFound(word)
    }

    /// A name usable as an environment variable: a letter or `_`, then letters, digits or `_`.
    public static func isVariableName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// Just enough shell word splitting to find a program name: quotes and backslashes, no expansion.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                inWord = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                inWord = true
                continue
            }
            if character.isWhitespace || ";|&<>".contains(character) {
                if inWord { words.append(current) }
                current = ""
                inWord = false
                if !character.isWhitespace { break }
                continue
            }
            current.append(character)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }
}
