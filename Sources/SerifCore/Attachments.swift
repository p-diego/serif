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
    /// The pictures Codex takes as `localImage` and the text marks "(image)"; the others stay a plain path to convert.
    public static let inputImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
}

/// Where a day's attachments go, relative to the shared folder: `allegati/2026-10-15`.
public func attachmentFolder(day: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd"
    return "\(AttachmentRules.folder)/\(f.string(from: day))"
}

/// A file name as the engine writes it: its last path component only (never a path of its own), `file` when empty,
/// control characters and newlines turned into spaces, at most 200 UTF-8 bytes with the extension kept (APFS: 255).
public func safeFileName(_ name: String) -> String {
    let flat = String(String.UnicodeScalarView((name as NSString).lastPathComponent.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
    }))
    let last = flat.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !last.isEmpty, last != ".", last != ".." else { return "file" }
    guard last.utf8.count > 200 else { return last }
    let ext = (last as NSString).pathExtension
    let keep = ext.isEmpty || ext.utf8.count > 20 ? "" : "." + ext
    var base = String(last.dropLast(keep.count))
    while base.utf8.count + keep.utf8.count > 200 { base.removeLast() }
    return base + keep
}

/// `name`, or `name-2`, `name-3`… before the extension: the first not in `taken`, compared without case as APFS does.
public func uniqueFileName(_ name: String, taken: Set<String>) -> String {
    let taken = Set(taken.map { $0.lowercased() })
    guard taken.contains(name.lowercased()) else { return name }
    let ext = (name as NSString).pathExtension
    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
        if !taken.contains(candidate.lowercased()) { return candidate }
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

/// A picture the bots take as an image (Codex `localImage`, "(image)" in the text): not heic, tiff or bmp.
public func isInputImage(_ path: String) -> Bool {
    AttachmentRules.inputImageExtensions.contains((path as NSString).pathExtension.lowercased())
}

/// What the bot reads under its message (spec §4): the files by their path in the shared folder, images marked.
public func attachmentsText(_ paths: [String]) -> String {
    "Attached files (in the project's shared folder):\n"
        + paths.map { "- \($0)" + (isInputImage($0) ? " (image)" : "") }.joined(separator: "\n")
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
    for path in attachments where isInputImage(path) {
        items.append(["type": "localImage", "path": .string((sharedFolder as NSString).appendingPathComponent(path))])
    }
    return .array(items)
}
