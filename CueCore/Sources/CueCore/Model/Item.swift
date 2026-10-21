import Foundation

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case service, task, link
}

public enum Tint: String, Codable, Sendable, CaseIterable {
    case sky, rose, amber, sage, plum, sand
}

public enum Shell: String, Codable, Sendable, CaseIterable {
    case zsh, bash, sh

    public var path: String { "/bin/\(rawValue)" }
}

public struct EnvironmentVariable: Codable, Sendable, Hashable {
    public var key: String
    /// Always empty for secrets: their values live in the Keychain and are never encoded.
    public var value: String
    public var isSecret: Bool

    public init(key: String, value: String = "", isSecret: Bool = false) {
        self.key = key
        self.value = isSecret ? "" : value
        self.isSecret = isSecret
    }

    enum CodingKeys: String, CodingKey { case key, value, isSecret }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        self.init(
            key: try container.decode(String.self, forKey: .key),
            value: try container.decodeIfPresent(String.self, forKey: .value) ?? "",
            isSecret: isSecret
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if isSecret {
            try container.encode(true, forKey: .isSecret)
        } else {
            try container.encode(value, forKey: .value)
        }
    }
}

public struct Input: Codable, Sendable, Hashable {
    public var name: String
    public var defaultValue: String

    public init(name: String, defaultValue: String = "") {
        self.name = name
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey { case name, defaultValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
    }
}

/// How long a task may run before Cue stops it. Encoded as seconds, or null for none.
public enum TimeLimit: Sendable, Hashable, Codable {
    case none
    case seconds(Int)

    public static let presets: [TimeLimit] = [.none, .seconds(30), .seconds(120), .seconds(600)]

    public var duration: Duration? {
        if case .seconds(let seconds) = self, seconds > 0 { return .seconds(seconds) }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            let seconds = try container.decode(Int.self)
            self = seconds > 0 ? .seconds(seconds) : .none
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none: try container.encodeNil()
        case .seconds(let seconds): try container.encode(seconds)
        }
    }
}

/// A service's check. Encoded as `"process"`, `{"port": "4000"}` or `{"statusCommand": "…"}`.
public enum RunningWhen: Sendable, Hashable, Codable {
    case process
    case port(String)
    case statusCommand(String)

    enum CodingKeys: String, CodingKey { case port, statusCommand }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            guard value == "process" else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Expected \"process\", got \"\(value)\"")
            }
            self = .process
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.port) {
            if let port = try? container.decode(Int.self, forKey: .port) {
                self = .port(String(port))
            } else {
                self = .port(try container.decode(String.self, forKey: .port))
            }
        } else {
            self = .statusCommand(try container.decode(String.self, forKey: .statusCommand))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .process:
            var single = encoder.singleValueContainer()
            try single.encode("process")
        case .port(let port):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(port, forKey: .port)
        case .statusCommand(let command):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .statusCommand)
        }
    }
}

/// How a service is stopped. Encoded as `"process"` or `{"command": "…"}`.
public enum StopBy: Sendable, Hashable, Codable {
    case process
    case command(String)

    enum CodingKeys: String, CodingKey { case command }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            guard value == "process" else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Expected \"process\", got \"\(value)\"")
            }
            self = .process
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .command(try container.decode(String.self, forKey: .command))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .process:
            var single = encoder.singleValueContainer()
            try single.encode("process")
        case .command(let command):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .command)
        }
    }
}

/// A service, task or link. Every field exists on every item, so changing the kind in the
/// editor keeps what was typed; only the fields that matter for the kind are written to disk.
public struct Item: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: ItemKind
    public var name: String
    public var icon: String
    public var tint: Tint
    public var order: Int

    // Task and Service
    public var command: String
    public var workingDirectory: String
    public var shell: Shell
    public var environment: [EnvironmentVariable]
    public var inputs: [Input]
    public var lastInputs: [String: String]
    public var timeLimit: TimeLimit
    public var confirmBeforeRunning: Bool
    public var keepOutput: Bool
    public var testedSignature: String?

    // Service
    public var runningWhen: RunningWhen
    public var stopBy: StopBy
    public var address: String?

    // Link
    public var target: String

    public init(
        id: UUID = UUID(),
        kind: ItemKind,
        name: String,
        icon: String? = nil,
        tint: Tint = .sky,
        order: Int = 0,
        command: String = "",
        workingDirectory: String = "~",
        shell: Shell = .zsh,
        environment: [EnvironmentVariable] = [],
        inputs: [Input] = [],
        lastInputs: [String: String] = [:],
        timeLimit: TimeLimit = .none,
        confirmBeforeRunning: Bool = false,
        keepOutput: Bool = true,
        testedSignature: String? = nil,
        runningWhen: RunningWhen = .process,
        stopBy: StopBy = .process,
        address: String? = nil,
        target: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.icon = icon ?? Self.defaultIcon(for: kind)
        self.tint = tint
        self.order = order
        self.command = command
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.environment = environment
        self.inputs = inputs
        self.lastInputs = lastInputs
        self.timeLimit = timeLimit
        self.confirmBeforeRunning = confirmBeforeRunning
        self.keepOutput = keepOutput
        self.testedSignature = testedSignature
        self.runningWhen = runningWhen
        self.stopBy = stopBy
        self.address = address
        self.target = target
    }

    public static func defaultIcon(for kind: ItemKind) -> String {
        switch kind {
        case .service: "server.rack"
        case .task: "terminal"
        case .link: "link"
        }
    }

    public var runsCommands: Bool { kind != .link }

    /// The values `inputs` take for a run: last used, then defaults.
    public var currentInputValues: [String: String] {
        Dictionary(inputs.map { ($0.name, lastInputs[$0.name] ?? $0.defaultValue) }, uniquingKeysWith: { _, last in last })
    }
}

extension Item: Codable {
    enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, tint, order
        case command, workingDirectory, shell, environment, inputs, lastInputs
        case timeLimit, confirmBeforeRunning, keepOutput, testedSignature
        case runningWhen, stopBy, address, target
    }

    /// Lenient, so a hand-written items.json only needs `kind` and `name` plus what the kind uses.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(ItemKind.self, forKey: .kind)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: kind,
            name: try c.decode(String.self, forKey: .name),
            icon: try c.decodeIfPresent(String.self, forKey: .icon),
            tint: try c.decodeIfPresent(Tint.self, forKey: .tint) ?? .sky,
            order: try c.decodeIfPresent(Int.self, forKey: .order) ?? 0,
            command: try c.decodeIfPresent(String.self, forKey: .command) ?? "",
            workingDirectory: try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "~",
            shell: try c.decodeIfPresent(Shell.self, forKey: .shell) ?? .zsh,
            environment: try c.decodeIfPresent([EnvironmentVariable].self, forKey: .environment) ?? [],
            inputs: try c.decodeIfPresent([Input].self, forKey: .inputs) ?? [],
            lastInputs: try c.decodeIfPresent([String: String].self, forKey: .lastInputs) ?? [:],
            timeLimit: try c.decodeIfPresent(TimeLimit.self, forKey: .timeLimit) ?? .none,
            confirmBeforeRunning: try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeRunning) ?? false,
            keepOutput: try c.decodeIfPresent(Bool.self, forKey: .keepOutput) ?? true,
            testedSignature: try c.decodeIfPresent(String.self, forKey: .testedSignature),
            runningWhen: try c.decodeIfPresent(RunningWhen.self, forKey: .runningWhen) ?? .process,
            stopBy: try c.decodeIfPresent(StopBy.self, forKey: .stopBy) ?? .process,
            address: try c.decodeIfPresent(String.self, forKey: .address),
            target: try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(tint, forKey: .tint)
        try c.encode(order, forKey: .order)
        if kind == .link {
            try c.encode(target, forKey: .target)
            return
        }
        try c.encode(command, forKey: .command)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(shell, forKey: .shell)
        try c.encode(environment, forKey: .environment)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(lastInputs, forKey: .lastInputs)
        try c.encode(timeLimit, forKey: .timeLimit)
        try c.encode(confirmBeforeRunning, forKey: .confirmBeforeRunning)
        try c.encode(keepOutput, forKey: .keepOutput)
        try c.encodeIfPresent(testedSignature, forKey: .testedSignature)
        if kind == .service {
            try c.encode(runningWhen, forKey: .runningWhen)
            try c.encode(stopBy, forKey: .stopBy)
            try c.encodeIfPresent(address, forKey: .address)
        }
    }
}
