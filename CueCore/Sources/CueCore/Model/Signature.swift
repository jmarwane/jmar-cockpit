import CryptoKit
import Foundation

extension Item {
    /// What a test run vouches for. Name, icon, tint and order don't change behavior, so they're left out;
    /// secret values never leave the Keychain, so only their keys count.
    private struct SignatureFields: Encodable {
        let kind: ItemKind
        let command: String
        let workingDirectory: String
        let shell: Shell
        let environment: [EnvironmentVariable]
        let inputs: [Input]
        let runningWhen: RunningWhen?
        let stopBy: StopBy?
    }

    public var signature: String {
        let fields = SignatureFields(
            kind: kind,
            command: command,
            workingDirectory: workingDirectory,
            shell: shell,
            environment: environment,
            inputs: inputs,
            runningWhen: kind == .service ? runningWhen : nil,
            stopBy: kind == .service ? stopBy : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Links never need testing; tasks and services do until a test run passes with this exact setup.
    public var isTested: Bool {
        kind == .link || testedSignature == signature
    }
}
