import Foundation

/// The quick-add guess for text typed or pasted into the search field (spec §6).
public enum Classifier {
    public enum Kind: String, Sendable, CaseIterable {
        case link = "Link"
        case command = "Command"
        case reminder = "Reminder"

        /// Tab cycles through the three.
        public var next: Kind {
            let all = Kind.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    public struct Guess: Sendable, Equatable {
        public var kind: Kind
        /// The input, with a pasted `$ ` or `% ` prompt removed.
        public var text: String
        /// For a reminder: the text without its time phrase, and the time.
        public var reminder: ReminderParser.Parsed
    }

    /// Rules in order, first match wins: link, shell syntax, time phrase, program on PATH, else reminder.
    public static func classify(_ input: String, path: String, now: Date = Date(), calendar: Calendar = .current) -> Guess {
        let text = stripPrompt(input)
        let reminder = ReminderParser.parse(text, now: now, calendar: calendar)
        func guess(_ kind: Kind) -> Guess { Guess(kind: kind, text: text, reminder: reminder) }

        if isLink(text) { return guess(.link) }
        if looksLikeShell(text) { return guess(.command) }
        if reminder.due != nil { return guess(.reminder) }
        if let word = ProgramResolver.programWord(of: text) {
            switch ProgramResolver.resolveWord(word, path: path, folder: NSHomeDirectory()) {
            case .path, .builtin: return guess(.command)
            case .notFound: break
            }
        }
        return guess(.reminder)
    }

    /// Removes a leading `$ ` or `% ` from each line of a pasted command, and outer whitespace.
    public static func stripPrompt(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$ ") || trimmed.hasPrefix("% ") else { return trimmed }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("$ ") || line.hasPrefix("% ") ? String(line.dropFirst(2)) : String(line)
        }.joined(separator: "\n")
    }

    /// `http(s)://…`, `localhost[:port][/path]`, `127.0.0.1:port`, or a bare domain like `example.com/docs`.
    public static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let patterns = [
            #"^https?://\S+$"#,
            #"^localhost(:\d{1,5})?(/\S*)?$"#,
            #"^(\d{1,3}\.){3}\d{1,3}(:\d{1,5})?(/\S*)?$"#,
            #"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(:\d{1,5})?(/\S*)?$"#,
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// `|`, `&&`, `;`, `>`, `$`, backticks, a flag like ` -x` or ` --flag`, or a leading `./`, `~/` or `/`.
    public static func looksLikeShell(_ text: String) -> Bool {
        if text.hasPrefix("./") || text.hasPrefix("~/") || text.hasPrefix("/") { return true }
        if text.contains("|") || text.contains("&&") || text.contains(";") || text.contains(">") || text.contains("$") || text.contains("`") {
            return true
        }
        return text.range(of: #"\s--?[A-Za-z]"#, options: .regularExpression) != nil
    }

    /// A link's name: the last part of the page path, or else the host.
    public static func linkName(_ target: String) -> String {
        guard let url = LinkTarget.url(for: target) else { return target }
        if url.isFileURL { return url.lastPathComponent.isEmpty ? target : (url.lastPathComponent as NSString).deletingPathExtension }
        let last = url.path.split(separator: "/").last.map(String.init)
        if let last, !last.isEmpty {
            return ItemSuggestions.humanize(last.removingPercentEncoding ?? last)
        }
        var host = url.host ?? target
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
