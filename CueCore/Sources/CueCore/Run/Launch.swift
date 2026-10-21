import Foundation

/// Where secret environment values come from. The app reads the Keychain; tests use a dictionary.
public protocol SecretStore: Sendable {
    func secret(itemID: UUID, key: String) -> String?
}

public struct InMemorySecretStore: SecretStore {
    public var values: [String: String]

    public init(_ values: [UUID: [String: String]] = [:]) {
        self.values = [:]
        for (id, pairs) in values {
            for (key, value) in pairs { self.values["\(id.uuidString).\(key)"] = value }
        }
    }

    public func secret(itemID: UUID, key: String) -> String? {
        values["\(itemID.uuidString).\(key)"]
    }
}

public enum LaunchError: Error, Sendable, Equatable, CustomStringConvertible {
    case folderNotFound(String)
    case missingSecret(String)
    case invalidPort(Placeholders.InvalidPort)

    public var description: String {
        switch self {
        case .folderNotFound(let folder): "Folder not found: \(folder)"
        case .missingSecret(let key): "Secret \(key) isn't in the Keychain"
        case .invalidPort(let error): error.description
        }
    }
}

/// Everything needed to spawn one command: `<shell> -c <command>` in a folder with an environment.
public struct LaunchSpec: Sendable, Equatable {
    public var shell: String
    public var command: String
    public var environment: [String: String]
    public var workingDirectory: String
    public var redactor: Redactor

    public var arguments: [String] { ["-c", command] }

    /// Builds the spawn for `command` (the item's own, or its status or stop command).
    /// Inputs reach the command only as environment variables, never spliced into its text.
    public static func make(
        command: String,
        for item: Item,
        inputs: [String: String],
        baseEnvironment: [String: String],
        secrets: any SecretStore
    ) throws(LaunchError) -> LaunchSpec {
        let folder = expandFolder(item.workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .folderNotFound(item.workingDirectory)
        }

        var environment = baseEnvironment
        environment["CUE"] = "1"
        var secretValues: [String] = []
        for variable in item.environment where !variable.key.isEmpty {
            if variable.isSecret {
                guard let value = secrets.secret(itemID: item.id, key: variable.key) else {
                    throw .missingSecret(variable.key)
                }
                environment[variable.key] = value
                secretValues.append(value)
            } else {
                environment[variable.key] = variable.value
            }
        }
        for input in item.inputs where !input.name.isEmpty {
            environment[input.name] = inputs[input.name] ?? input.defaultValue
        }

        return LaunchSpec(
            shell: item.shell.path,
            command: command,
            environment: environment,
            workingDirectory: folder,
            redactor: Redactor(secrets: secretValues)
        )
    }

    /// `~` and `~/…` become the home folder; anything else is used as written.
    public static func expandFolder(_ folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") { return NSHomeDirectory() + trimmed.dropFirst(1) }
        return trimmed
    }

    /// Values for `$NAME` in the port and address fields: the item's plain environment, then its inputs.
    public static func placeholderValues(for item: Item, inputs: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for variable in item.environment where !variable.isSecret { values[variable.key] = variable.value }
        for input in item.inputs { values[input.name] = inputs[input.name] ?? input.defaultValue }
        return values
    }
}
