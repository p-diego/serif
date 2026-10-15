import Foundation

/// Where a user message came from: typed in the Serif chat or in the bot's terminal, Serif's own first message to a new
/// bot (spec §5 of 0.3), which the chat shows as a system line rather than as yours, or mail from another bot (spec §6
/// of 0.5), which the chat shows as its `mail` item.
public enum MessageOrigin: String, Codable, Sendable { case chat, terminal, introduction, bot }

/// Informational lines shown in the chat timeline. `introductionRequested` is never stored: `Transcript` shows the
/// introduction's user message as this line.
public enum SystemNote: Codable, Equatable, Sendable {
    case botCreated, resumed, newConversation, compacted, interrupted, introductionRequested
    case linkedFolderMissing(path: String)
    case crashed(reason: String)
    case messageMayNotHaveArrived(text: String)     // sent to Codex, whose server went before answering: not sent again
    case createdBy(name: String)                    // in place of `botCreated` for a bot another bot created (spec §7)
}

/// What a working bot is doing right now, shown next to its name.
public enum Activity: Codable, Equatable, Sendable {
    case thinking, typing
    case runningCommand(String?)        // Bash description or command
    case reading(String)                // file name (last path component)
    case editing(String)
    case searching
    case browsing                        // WebSearch / WebFetch
    case delegating                      // Task / Agent subagent
    case tool(String)                    // any other tool name

    /// Maps a tool call from the transcript or hook payload to an activity.
    public static func from(toolName: String, input: JSONValue) -> Activity {
        func lastComponent(_ path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
        switch toolName {
        case "Bash":
            return .runningCommand(input["description"]?.string ?? input["command"]?.string)
        case "Read":
            if let path = input["file_path"]?.string { return .reading(lastComponent(path)) }
        case "Edit", "Write", "MultiEdit":
            if let path = input["file_path"]?.string { return .editing(lastComponent(path)) }
        case "NotebookEdit":
            if let path = input["notebook_path"]?.string { return .editing(lastComponent(path)) }
        case "Grep", "Glob":
            return .searching
        case "WebFetch", "WebSearch":
            return .browsing
        case "Task", "Agent":
            return .delegating
        default:
            break
        }
        return .tool(toolName)
    }
}

/// One entry of a bot's chat timeline. Streams are split into deltas and a final flag.
public enum ChatEvent: Codable, Equatable, Sendable {
    case userMessage(text: String, promptId: String?, origin: MessageOrigin)
    case assistantText(messageId: String, index: Int, delta: String, final: Bool, promptId: String?)
    case assistantTextReplaced(messageId: String, text: String)
    case toolStarted(toolUseId: String, name: String, input: JSONValue, promptId: String?)
    case toolFinished(toolUseId: String, ok: Bool, output: String, durationMs: Int?)
    case requestOpened(PendingRequest)
    case requestClosed(requestId: UUID, resolution: RequestResolution, answer: RequestAnswer? = nil)
    case turnEnded(promptId: String?, lastMessage: String?)
    case turnFailed(reason: String)
    case turnInterrupted
    case subagent(started: Bool, agentType: String?)
    case system(SystemNote)
    case mail(MailNote)             // a mail message sent or received (spec §6)
    case task(TaskCard)             // a task, recorded again at every change of its status (spec §6)
}

/// A chat event with its per-bot sequence number and time.
public struct ChatEventRecord: Codable, Equatable, Sendable {
    public let seq: Int
    public let at: Date
    public let event: ChatEvent

    public init(seq: Int, at: Date, event: ChatEvent) {
        self.seq = seq
        self.at = at
        self.event = event
    }
}
