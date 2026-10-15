import Foundation

// Mail between the bots of a project (spec §5–6).

/// What a mail message is: a task, a reply about one, a note, or a notice of the engine's (spec §5).
public enum MailKind: String, Codable, Sendable { case task, reply, note, system }

/// Where a task stands (spec §5); only an open one changes.
public enum TaskStatus: String, Codable, Sendable { case open, done, cancelled, expired }

/// What a message of the engine's says (spec §5–6): its English text for the bot and the app's line are both made from
/// it. `done` also marks the reply that closes a task.
public enum MailNotice: String, Codable, Sendable {
    case done, cancelledByRequester, cancelledByUser, cancelledArchived, expired
}

public enum MailDirection: String, Codable, Sendable { case sent, received }

/// A mail message in a bot's chat (spec §6): received (a bubble, or a line for a notice) or sent (a line). Names as
/// they were then.
public struct MailNote: Codable, Equatable, Sendable {
    public var messageId: UUID
    public var kind: MailKind
    public var from: String
    public var to: String
    public var direction: MailDirection
    /// The body, the result or the reason; for a notice, its whole English text.
    public var text: String
    public var taskNumber: Int?
    public var notice: MailNotice?

    public init(messageId: UUID, kind: MailKind, from: String, to: String, direction: MailDirection, text: String,
                taskNumber: Int? = nil, notice: MailNotice? = nil) {
        self.messageId = messageId; self.kind = kind; self.from = from; self.to = to; self.direction = direction
        self.text = text; self.taskNumber = taskNumber; self.notice = notice
    }
}

/// A task as both chats show it (spec §6), recorded again at every change of its status.
public struct TaskCard: Codable, Equatable, Sendable {
    public var number: Int
    public var from: String
    public var to: String
    public var text: String
    public var deadline: Date
    public var status: TaskStatus
    public var result: String?

    public init(number: Int, from: String, to: String, text: String, deadline: Date, status: TaskStatus,
                result: String? = nil) {
        self.number = number; self.from = from; self.to = to; self.text = text; self.deadline = deadline
        self.status = status; self.result = result
    }
}
