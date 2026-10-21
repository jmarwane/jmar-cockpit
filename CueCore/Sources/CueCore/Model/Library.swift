import Foundation

/// The contents of items.json.
public struct Library: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var items: [Item]
    public var reminders: [Reminder]

    public init(items: [Item] = [], reminders: [Reminder] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.items = items
        self.reminders = reminders
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, items, reminders }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        reminders = try c.decodeIfPresent([Reminder].self, forKey: .reminders) ?? []
    }

    /// Items in the user's order.
    public var orderedItems: [Item] {
        items.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }
}
