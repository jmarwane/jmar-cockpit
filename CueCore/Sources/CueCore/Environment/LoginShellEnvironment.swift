import Darwin
import Foundation

/// The environment commands run with, captured once from the user's login shell.
public struct CapturedEnvironment: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// `$SHELL -ilc`
        case interactiveLogin
        /// `$SHELL -lc`, after the interactive attempt failed or timed out
        case login
        /// Cue's own environment with `LoginShellEnvironment.defaultPATH`
        case fallback
    }

    public let variables: [String: String]
    public let source: Source

    public var path: String { variables["PATH"] ?? "" }
}

public enum LoginShellEnvironment {
    public static let defaultPATH =
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Variables that describe the capturing shell itself, not the user's setup.
    static let shellLocalKeys: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD"]

    /// The user's login shell from the directory service, then `$SHELL`, then zsh.
    public static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Tries `shell -ilc`, then `shell -lc`, each with `timeout`, then falls back to
    /// `baseEnvironment` with the default PATH.
    public static func capture(
        shell: String = userShell,
        timeout: Duration = .seconds(5),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> CapturedEnvironment {
        for (flags, source) in [("-ilc", CapturedEnvironment.Source.interactiveLogin), ("-lc", .login)] {
            if let variables = await run(shell: shell, flags: flags, timeout: timeout, environment: baseEnvironment) {
                return CapturedEnvironment(variables: variables, source: source)
            }
        }
        var variables = baseEnvironment
        variables["PATH"] = defaultPATH
        return CapturedEnvironment(variables: variables, source: .fallback)
    }

    /// Runs the shell once and returns the variables printed between the markers,
    /// or nil if it timed out, failed to launch, or never printed both markers.
    static func run(
        shell: String,
        flags: String,
        timeout: Duration,
        environment: [String: String]
    ) async -> [String: String]? {
        // The command builds each marker from two pieces, so a shell that echoes
        // its command line (set -x, verbose plugins) never prints a whole marker early.
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = "__CUE_ENV_START_\(token)__"
        let end = "__CUE_ENV_END_\(token)__"
        let command = "printf '%s%s' '__CUE_ENV_START_' '\(token)__'; /usr/bin/env -0; printf '%s%s' '__CUE_ENV_END_' '\(token)__'"

        let process: SpawnedProcess
        do {
            process = try ProcessGroup.spawn(
                executable: shell,
                arguments: [flags, command],
                environment: environment,
                outputLimit: 4 * 1024 * 1024
            )
        } catch {
            return nil
        }

        guard await process.waitForExit(timeout: timeout) != nil else {
            await process.terminateGroup(grace: .milliseconds(500))
            return nil
        }
        // Something started by the shell may still hold the pipe open; don't wait on it for long.
        _ = await process.output?.waitForEnd(timeout: .milliseconds(500))
        guard let output = process.output?.data else { return nil }
        return parse(output, start: start, end: end)
    }

    /// Parses NUL-separated `KEY=value` pairs between the last start marker and the end marker after it.
    static func parse(_ output: Data, start: String, end: String) -> [String: String]? {
        guard let startRange = output.range(of: Data(start.utf8), options: .backwards),
              let endRange = output.range(of: Data(end.utf8), in: startRange.upperBound..<output.endIndex)
        else { return nil }

        var variables: [String: String] = [:]
        for entry in output[startRange.upperBound..<endRange.lowerBound].split(separator: 0) {
            guard let pair = String(data: Data(entry), encoding: .utf8),
                  let equals = pair.firstIndex(of: "="),
                  equals != pair.startIndex
            else { continue }
            let key = String(pair[..<equals])
            guard !shellLocalKeys.contains(key) else { continue }
            variables[key] = String(pair[pair.index(after: equals)...])
        }
        return variables.isEmpty ? nil : variables
    }
}
