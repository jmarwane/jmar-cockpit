import Foundation

/// Guesses for a new command: kind, name, icon and tint. The editor fills these in; the user can change them.
public enum ItemSuggestions {
    /// The icon picker's choices.
    public static let icons = [
        "server.rack", "terminal", "play.circle", "shippingbox", "cylinder.split.1x2", "hammer",
        "doc.text", "arrow.triangle.branch", "globe", "folder", "waveform", "bolt",
        "externaldrive", "checkmark.seal", "chart.bar", "link",
    ]

    static let serviceWords: Set<String> = ["dev", "serve", "server", "watch", "up"]

    /// Service if the command says `dev`, `serve`, `server`, `watch` or `up` as a word; otherwise Task.
    public static func kind(for command: String) -> ItemKind {
        words(in: command).contains { serviceWords.contains($0) } ? .service : .task
    }

    static let runners: Set<String> = [
        "npm", "npx", "yarn", "pnpm", "bun", "make", "docker", "docker-compose", "brew", "python", "python3",
        "node", "ruby", "go", "cargo", "swift", "sh", "bash", "zsh", "uv", "poetry", "deno",
    ]

    /// `splash serve` → "Splash serve"; `./scripts/weekly-report.sh` → "Weekly report";
    /// `npm run dev` in ~/Code/splash → "Splash dev".
    public static func name(for command: String, folder: String = "~") -> String {
        let words = ShellWords.split(command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .filter { !ProgramResolver.isAssignment($0) && !ProgramResolver.wrappers.contains($0) }
        guard let first = words.first else { return "New Item" }

        if first.contains("/") {
            let file = (first as NSString).lastPathComponent
            return humanize((file as NSString).deletingPathExtension)
        }
        let rest = words.dropFirst().filter {
            !$0.hasPrefix("-") && !$0.contains("/") && !$0.contains("=") && $0 != "run" && $0 != "exec" && $0 != "compose"
        }
        if runners.contains(first) {
            let script = words.dropFirst().first { !$0.hasPrefix("-") && ($0.contains("/") || $0.contains(".")) }
            if let script {
                return humanize(((script as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            let folderName = (LaunchSpec.expandFolder(folder) as NSString).lastPathComponent
            let base = folder.trimmingCharacters(in: .whitespaces).isEmpty || folder == "~" ? first : folderName
            return humanize(([base] + rest.prefix(1)).joined(separator: " "))
        }
        return humanize(([first] + rest.prefix(1)).joined(separator: " "))
    }

    public static func icon(for command: String, kind: ItemKind) -> String {
        let words = words(in: command)
        func has(_ candidates: String...) -> Bool { candidates.contains { words.contains($0) } }
        if kind == .link { return "link" }
        if has("docker", "compose", "podman") { return "shippingbox" }
        if has("postgres", "psql", "mysql", "redis", "mongod", "db", "database") { return "cylinder.split.1x2" }
        if has("git") { return "arrow.triangle.branch" }
        if has("rsync", "backup", "restic", "borg") { return "externaldrive" }
        if has("test", "pytest", "jest", "vitest", "check", "lint") { return "checkmark.seal" }
        if has("build", "make", "cargo", "compile") { return "hammer" }
        if has("report", "csv", "export") { return "doc.text" }
        if has("audio", "ffmpeg", "sox", "music") { return "waveform" }
        if kind == .service { return "server.rack" }
        return "terminal"
    }

    /// A stable tint from the name, so each new item gets a different but repeatable color.
    public static func tint(for name: String) -> Tint {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return Tint.allCases[sum % Tint.allCases.count]
    }

    static func words(in command: String) -> [String] {
        command.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    public static func humanize(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return text }
        return first.uppercased() + spaced.dropFirst()
    }
}
