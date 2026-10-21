import Foundation

public struct Reminder: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, fired }

    public var id: UUID
    public var text: String
    public var due: Date
    public var state: State
    public var firedAt: Date?
    public var notificationID: String

    public init(id: UUID = UUID(), text: String, due: Date, state: State = .pending, firedAt: Date? = nil, notificationID: String? = nil) {
        self.id = id
        self.text = text
        self.due = due
        self.state = state
        self.firedAt = firedAt
        self.notificationID = notificationID ?? "cue.reminder.\(id.uuidString)"
    }
}
