import Foundation

/// One tool call inside a `steps` group.
public struct Step: Equatable, Identifiable, Sendable {
    public let id: String            // toolUseId
    public var name: String
    public var input: JSONValue
    public var output: String?
    public var ok: Bool?
    public var durationMs: Int?

    public init(id: String, name: String, input: JSONValue, output: String? = nil, ok: Bool? = nil, durationMs: Int? = nil) {
        self.id = id; self.name = name; self.input = input
        self.output = output; self.ok = ok; self.durationMs = durationMs
    }

    /// The command or the file (spec §4.2), else the description, else the tool name. Claude Code gives every Bash call a
    /// description too, so description-first never showed a command.
    public var title: String {
        if let c = input["command"]?.string { return c }
        if let p = input["file_path"]?.string { return p.split(separator: "/").last.map(String.init) ?? p }
        if let d = input["description"]?.string { return d }
        return name
    }
}

public enum StepsStatus: Equatable, Sendable { case running, done, failed }

public enum ChatItem: Equatable, Identifiable, Sendable {
    case timestamp(id: String, at: Date)
    case user(id: String, text: String, origin: MessageOrigin, at: Date)
    case assistant(id: String, text: String, at: Date, streaming: Bool)
    case steps(id: String, steps: [Step], status: StepsStatus)
    case request(id: String, request: PendingRequest, resolution: RequestResolution?, answer: RequestAnswer?)
    case system(id: String, note: SystemNote, at: Date)

    public var id: String {
        switch self {
        case .timestamp(let id, _), .user(let id, _, _, _), .assistant(let id, _, _, _),
             .steps(let id, _, _), .request(let id, _, _, _), .system(let id, _, _): return id
        }
    }
}

/// Folds chat events into the items the chat view renders.
public struct Transcript: Equatable, Sendable {
    public private(set) var items: [ChatItem] = []
    public private(set) var lastSeq: Int = 0
    /// The oldest record loaded: older history exists when it is above 1.
    public var firstSeq: Int? { records.first?.seq }
    private var records: [ChatEventRecord] = []    // kept so `prepend` can rebuild
    private var lastAt: Date?                      // time of the last non-timestamp item
    private var openSteps: Int?                    // index of the steps item still accepting tools

    public init() {}

    /// Equality is about what the UI shows; the record history is bookkeeping.
    public static func == (a: Transcript, b: Transcript) -> Bool { a.items == b.items && a.lastSeq == b.lastSeq }

    public mutating func apply(_ records: [ChatEventRecord]) { records.forEach { apply($0) } }

    public mutating func apply(_ record: ChatEventRecord) {
        guard record.seq > lastSeq else { return }
        lastSeq = record.seq
        records.append(record)
        fold(record)
    }

    /// History paging: rebuilds from older + already applied records, deduplicated by seq.
    public mutating func prepend(_ older: [ChatEventRecord]) {
        var bySeq: [Int: ChatEventRecord] = [:]
        for r in older + records { bySeq[r.seq] = r }
        let merged = bySeq.values.sorted { $0.seq < $1.seq }
        self = Transcript()
        apply(merged)
    }

    // MARK: folding

    private mutating func add(_ item: ChatItem, _ r: ChatEventRecord, keepSteps: Bool = false) {
        if lastAt == nil || r.at.timeIntervalSince(lastAt!) > 15 * 60 {
            items.append(.timestamp(id: "ts-\(r.seq)", at: r.at))
        }
        items.append(item)
        lastAt = r.at
        if !keepSteps { openSteps = nil }
    }

    private mutating func fold(_ r: ChatEventRecord) {
        switch r.event {
        case .userMessage(let text, _, let origin):
            add(.user(id: "u-\(r.seq)", text: text, origin: origin, at: r.at), r)
        case .assistantText(let id, _, let delta, let final, _):
            if let i = items.lastIndex(where: { if case .assistant(id, _, _, _) = $0 { true } else { false } }),
               case .assistant(_, var t, let at, _) = items[i] {
                items[i] = .timestamp(id: "", at: at)    // release the buffer so the append below is in place
                t += delta
                items[i] = .assistant(id: id, text: t, at: at, streaming: !final)
                lastAt = r.at
                openSteps = nil
            } else {
                add(.assistant(id: id, text: delta, at: r.at, streaming: !final), r)
            }
        case .assistantTextReplaced(let id, let text):
            if let i = items.lastIndex(where: { if case .assistant(id, _, _, _) = $0 { true } else { false } }),
               case .assistant(_, _, let at, let st) = items[i] {
                items[i] = .assistant(id: id, text: text, at: at, streaming: st)
            }
        case .toolStarted(let id, let name, let input, _):
            // Questions and plans show as their own card: a steps card for them would say the same thing twice.
            guard PendingRequest.kind(forTool: name) == .permission else { break }
            let step = Step(id: id, name: name, input: input)
            if let i = openSteps, case .steps(let sid, var steps, _) = items[i] {
                steps.append(step)
                items[i] = .steps(id: sid, steps: steps, status: Self.status(steps))
                lastAt = r.at
            } else {
                add(.steps(id: "steps-\(id)", steps: [step], status: .running), r, keepSteps: true)
                openSteps = items.count - 1
            }
        case .toolFinished(let id, let ok, let output, let ms):
            for i in items.indices.reversed() {
                guard case .steps(let sid, var steps, _) = items[i], let k = steps.firstIndex(where: { $0.id == id }) else { continue }
                steps[k].ok = ok; steps[k].output = output; steps[k].durationMs = ms
                items[i] = .steps(id: sid, steps: steps, status: Self.status(steps))
                break
            }
        case .requestOpened(let req):
            add(.request(id: req.id.uuidString, request: req, resolution: nil, answer: nil), r)
        case .requestClosed(let rid, let resolution, let answer):
            if let i = items.lastIndex(where: { if case .request(rid.uuidString, _, _, _) = $0 { true } else { false } }), case .request(let id, let req, _, _) = items[i] {
                items[i] = .request(id: id, request: req, resolution: resolution, answer: answer)
            }
        case .turnEnded:
            stopStreaming()
            openSteps = nil    // the next turn's tools start a new group
        case .turnInterrupted:
            stopStreaming()
            for i in items.indices {
                guard case .steps(let sid, var steps, .running) = items[i] else { continue }
                for k in steps.indices where steps[k].ok == nil { steps[k].ok = false }
                items[i] = .steps(id: sid, steps: steps, status: .failed)
            }
            add(.system(id: "sys-\(r.seq)", note: .interrupted, at: r.at), r)
        case .turnFailed(let reason):
            // No dedicated note exists for a failed turn: shown as a crash note.
            stopStreaming()
            add(.system(id: "sys-\(r.seq)", note: .crashed(reason: reason), at: r.at), r)
        case .system(let note):
            add(.system(id: "sys-\(r.seq)", note: note, at: r.at), r)
        case .subagent:
            break    // ignored in 0.1
        }
    }

    private mutating func stopStreaming() {
        for i in items.indices {
            if case .assistant(let id, let t, let at, true) = items[i] { items[i] = .assistant(id: id, text: t, at: at, streaming: false) }
        }
    }

    private static func status(_ steps: [Step]) -> StepsStatus {
        if steps.contains(where: { $0.ok == false }) { return .failed }
        return steps.contains(where: { $0.ok == nil }) ? .running : .done
    }
}
