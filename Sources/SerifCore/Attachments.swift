import Foundation

// Attachments (spec §4 of 0.7): files sent with a message of yours, copied into the project's shared folder under
// allegati/<day>/ and named in the text the bot reads; images reach Codex as input items too. And the notice that heads
// the next message after the bot's instructions changed (spec §6).

public enum AttachmentRules {
    public static let maxBytes = 16 << 20          // per file
    public static let maxFiles = 10                // per message
    public static let folder = "allegati"
    /// What the bots can look at as a picture (Claude Code's Read, Codex's `localImage`).
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif",
                                                      "bmp"]
}

/// Where a day's attachments go, relative to the shared folder: `allegati/2026-10-15`.
public func attachmentFolder(day: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd"
    return "\(AttachmentRules.folder)/\(f.string(from: day))"
}

/// A file name as the engine writes it: its last path component only (never a path of its own), `file` when empty.
public func safeFileName(_ name: String) -> String {
    let last = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return last.isEmpty || last == "." || last == ".." ? "file" : last
}

/// `name`, or `name-2`, `name-3`… before the extension: the first not in `taken` (spec §4).
public func uniqueFileName(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let ext = (name as NSString).pathExtension
    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
        if !taken.contains(candidate) { return candidate }
        n += 1
    }
}

/// Why a message's files cannot go (spec §4, §10), nil when they can: more than 10, or one over 16 MB.
public func attachmentProblem(_ files: [(name: String, bytes: Int)]) -> String? {
    if files.count > AttachmentRules.maxFiles { return "at most \(AttachmentRules.maxFiles) files per message" }
    if let big = files.first(where: { $0.bytes > AttachmentRules.maxBytes }) {
        return "\(big.name) is larger than 16 MB"
    }
    return nil
}

public func isImage(_ path: String) -> Bool {
    AttachmentRules.imageExtensions.contains((path as NSString).pathExtension.lowercased())
}

/// What the bot reads under its message (spec §4): the files by their path in the shared folder, images marked.
public func attachmentsText(_ paths: [String]) -> String {
    "Attached files (in the project's shared folder):\n"
        + paths.map { "- \($0)" + (isImage($0) ? " (image)" : "") }.joined(separator: "\n")
}

/// The message as the bot gets it: the text, then its files; the files alone when there is no text.
public func messageText(_ text: String, attachments: [String]) -> String {
    guard !attachments.isEmpty else { return text }
    return text.isEmpty ? attachmentsText(attachments) : text + "\n\n" + attachmentsText(attachments)
}

/// The notice at the head of the next message a bot gets after its instructions changed (spec §6), then the message.
public func instructionsNotice(_ instructions: String, before message: String) -> String {
    "Your instructions have changed. From now on follow these:\n\n\(instructions)\n\n---\n\n\(message)"
}

/// The `input` of a Codex turn (spec §4): the text, then each image as a `localImage` by its absolute path.
public func codexInput(text: String, attachments: [String], sharedFolder: String) -> JSONValue {
    var items: [JSONValue] = [["type": "text", "text": .string(text)]]
    for path in attachments where isImage(path) {
        items.append(["type": "localImage", "path": .string((sharedFolder as NSString).appendingPathComponent(path))])
    }
    return .array(items)
}
