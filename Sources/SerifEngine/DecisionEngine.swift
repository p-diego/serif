import Foundation
import SerifCore

// Decisions (spec §6 of 0.6): a choice a bot leaves to you, kept in the project's mail.json, shown as a card the engine
// itself answers (`Asker.engine`); the bot goes on meanwhile and gets your answer as mail from you.
extension Engine {
    /// The card of a decision: the same request id across restarts, so the chat never shows it twice.
    func decisionRequest(_ d: Decision) -> PendingRequest {
        var input: [String: JSONValue] = ["number": .number(Double(d.number)), "question": .string(d.question),
                                          "options": .array(d.options.map(JSONValue.string))]
        if let r = d.recommendation { input["recommendation"] = .number(Double(r)) }
        if let c = d.context { input["context"] = .string(c) }
        return PendingRequest(id: d.requestId, botId: d.botId, kind: .decision, toolName: "decision", input: .object(input),
                              toolUseId: nil, promptId: nil, suggestions: nil, openedAt: d.createdAt)
    }

    /// At the engine's start (spec §6): the open decisions are cards again, without a new record in the chat.
    func reviveDecisions() {
        for project in store.projects {
            for d in store.mailbox(project.id).decisions where d.status == .open && bots[d.botId]?.bot.archivedAt == nil {
                requests[d.requestId] = (decisionRequest(d), .engine)
            }
        }
    }

    /// `raise_decision` (spec §6): the card opens in the bot's chat and counts for you; the turn goes on.
    func raiseDecision(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let question = a["question"]?.string, let given = a["options"]?.array else {
            throw MailError("raise_decision needs question and options")
        }
        let options = given.compactMap(\.string)
        guard options.count == given.count else { throw MailError("options must be 2 to 6 short texts") }
        var box = store.mailbox(rt.bot.projectId)
        let recommendation = try number(a["recommendation"], "recommendation").map { $0 - 1 }      // the bot counts from 1
        let d = try box.raiseDecision(by: rt.bot.id, question: question, options: options, recommendation: recommendation,
                                      context: a["context"]?.string, at: now())
        try store.save(box, project: rt.bot.projectId)
        let request = decisionRequest(d)
        requests[request.id] = (request, .engine)
        record(.requestOpened(request), rt)
        push(.requestOpened(request))
        return "Decision #\(d.number) raised; you will get the answer as a message"
    }

    func listDecisions(for rt: BotRuntime) -> String {
        decisionsText(store.mailbox(rt.bot.projectId).decisions, name: botName)
    }

    /// `withdraw_decision` (spec §6): the card closes as withdrawn.
    func withdrawDecision(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let n = try number(a["number"], "number") else { throw MailError("withdraw_decision needs number") }
        var box = store.mailbox(rt.bot.projectId)
        let d = try box.withdrawDecision(n, by: rt.bot.id, reason: a["reason"]?.string, at: now())
        try store.save(box, project: rt.bot.projectId)
        closeRequest(d.requestId, .cancelled, replied: true)
        return "Decision #\(n) withdrawn"
    }

    /// Your answer from the card (spec §6): the decision is answered, the bot gets it as mail from you (delivered like
    /// any mail, once it is free), the lead a copy when it is another bot. The card closes in `answer`.
    func answerDecision(_ request: PendingRequest, option: Int?, text: String?) throws {
        guard let rt = bots[request.botId] else { throw Refusal("Unknown bot") }
        let project = rt.bot.projectId
        var box = store.mailbox(project)
        guard let d = box.decisions.first(where: { $0.requestId == request.id }) else { throw Refusal("The request is already closed") }
        let lead = store.projects.first { $0.id == project }?.leadBotId
        _ = try box.answerDecision(d.number, option: option, text: text, botName: rt.bot.name, lead: lead, at: now())
        save(box, project)                                  // your answer is the engine's move: kept if the disk fails
        deliverMail(in: project)
    }
}
