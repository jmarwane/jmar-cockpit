/// Replaces known secret values with `••••`.
public struct Redactor: Sendable, Hashable {
    public static let mask = "••••"
    /// Shorter values would mask ordinary text (a secret of "1" would hide every 1).
    public static let minimumLength = 4

    public let secrets: [String]

    public init(secrets: some Sequence<String> = []) {
        // Longest first, so a secret containing another is masked whole.
        self.secrets = Set(secrets.filter { $0.count >= Self.minimumLength })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    public func redact(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: Self.mask) }
    }
}
