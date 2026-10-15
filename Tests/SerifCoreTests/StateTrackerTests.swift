import Foundation
import XCTest
@testable import SerifCore

final class StateTrackerTests: XCTestCase {
    private let retry = Date(timeIntervalSince1970: 1_000)
    private let until = Date(timeIntervalSince1970: 2_000)

    private func request(kind: WaitKind = .permission) -> PendingRequest {
        PendingRequest(botId: UUID(), kind: kind, toolName: "Bash", input: .null,
                       toolUseId: nil, promptId: "p", suggestions: nil)
    }

    /// A tracker that has been started and is sitting in `.ready`.
    private func readyTracker() -> StateTracker {
        var s = StateTracker()
        s.sessionStarted()
        return s
    }

    /// A tracker in `.working(.thinking)`.
    private func workingTracker() -> StateTracker {
        var s = readyTracker()
        s.apply(.userMessage(text: "x", promptId: "p", origin: .chat))
        return s
    }

    // MARK: - Lifecycle

    func testStartsAsStarting() {
        XCTAssertEqual(StateTracker().state, .starting)
    }

    func testProcessStartedGoesToStarting() {
        var s = readyTracker()
        s.processStarted()
        XCTAssertEqual(s.state, .starting)
    }

    func testSessionStartedFromStartingGoesToReady() {
        var s = StateTracker()
        s.sessionStarted()
        XCTAssertEqual(s.state, .ready)
    }

    func testSessionStartedFromCrashedGoesToReady() {
        var s = workingTracker()
        s.processExited(reason: "boom", retryAt: retry)
        s.sessionStarted()
        XCTAssertEqual(s.state, .ready)
    }

    func testSessionStartedFromStoppedGoesToReady() {
        var s = workingTracker()
        s.stopped()
        s.sessionStarted()
        XCTAssertEqual(s.state, .ready)
    }

    func testSessionStartedKeepsWorking() {
        var s = workingTracker()
        s.sessionStarted()
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testSessionStartedKeepsWaiting() {
        var s = workingTracker()
        let r = request()
        s.apply(.requestOpened(r))
        s.sessionStarted()
        XCTAssertEqual(s.state, .waiting(kind: .permission, requestId: r.id))
    }

    func testSessionStartedKeepsRateLimited() {
        var s = workingTracker()
        s.rateLimited(until: until)
        s.sessionStarted()
        XCTAssertEqual(s.state, .rateLimited(until: until))
    }

    func testProcessExitedSetsCrashed() {
        var s = workingTracker()
        s.processExited(reason: "boom", retryAt: retry)
        XCTAssertEqual(s.state, .crashed(reason: "boom", retryAt: retry))
    }

    func testProcessExitedFromStartingSetsCrashed() {
        var s = StateTracker()
        s.processExited(reason: "early", retryAt: nil)
        XCTAssertEqual(s.state, .crashed(reason: "early", retryAt: nil))
    }

    func testProcessExitedOverridesRateLimited() {
        var s = workingTracker()
        s.rateLimited(until: until)
        s.processExited(reason: "boom", retryAt: nil)
        XCTAssertEqual(s.state, .crashed(reason: "boom", retryAt: nil))
    }

    func testStoppedSetsStopped() {
        var s = workingTracker()
        s.stopped()
        XCTAssertEqual(s.state, .stopped)
    }

    func testStoppedOverridesCrashed() {
        var s = workingTracker()
        s.processExited(reason: "boom", retryAt: retry)
        s.stopped()
        XCTAssertEqual(s.state, .stopped)
    }

    func testRateLimitedSetsRateLimited() {
        var s = workingTracker()
        s.rateLimited(until: until)
        XCTAssertEqual(s.state, .rateLimited(until: until))
    }

    func testRateLimitedWithoutDate() {
        var s = readyTracker()
        s.rateLimited(until: nil)
        XCTAssertEqual(s.state, .rateLimited(until: nil))
    }

    // MARK: - Events

    func testUserMessageStartsThinking() {
        var s = readyTracker()
        s.apply(.userMessage(text: "x", promptId: "p", origin: .terminal))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testAssistantTextIsTyping() {
        var s = workingTracker()
        s.apply(.assistantText(messageId: "m", index: 0, delta: "ciao", final: false, promptId: "p"))
        XCTAssertEqual(s.state, .working(.typing))
    }

    func testToolStartedMapsActivity() {
        var s = workingTracker()
        let input: JSONValue = .object(["command": .string("swift test"), "description": .string("Run tests")])
        s.apply(.toolStarted(toolUseId: "t1", name: "Bash", input: input, promptId: "p"))
        XCTAssertEqual(s.state, .working(.runningCommand("Run tests")))
    }

    func testToolStartedReadMapsToReading() {
        var s = workingTracker()
        s.apply(.toolStarted(toolUseId: "t1", name: "Read",
                             input: .object(["file_path": .string("/a/b/Foo.swift")]), promptId: "p"))
        XCTAssertEqual(s.state, .working(.reading("Foo.swift")))
    }

    func testToolFinishedBackToThinking() {
        var s = workingTracker()
        s.apply(.toolStarted(toolUseId: "t1", name: "Grep", input: .null, promptId: "p"))
        s.apply(.toolFinished(toolUseId: "t1", ok: true, output: "", durationMs: 5))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testRequestOpenedWaits() {
        var s = workingTracker()
        let r = request(kind: .question)
        s.apply(.requestOpened(r))
        XCTAssertEqual(s.state, .waiting(kind: .question, requestId: r.id))
    }

    func testRequestClosedBackToWorkingWhenWaitingOnIt() {
        var s = workingTracker()
        let r = request()
        s.apply(.requestOpened(r))
        s.apply(.requestClosed(requestId: r.id, resolution: .answeredInTerminal))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testRequestClosedForOtherIdKeepsWaiting() {
        var s = workingTracker()
        let r = request()
        s.apply(.requestOpened(r))
        s.apply(.requestClosed(requestId: UUID(), resolution: .cancelled))
        XCTAssertEqual(s.state, .waiting(kind: .permission, requestId: r.id))
    }

    func testWaitingSurvivesOtherToolAndTextEvents() {
        var s = workingTracker()
        let r = request()
        s.apply(.requestOpened(r))
        s.apply(.toolFinished(toolUseId: "other", ok: true, output: "", durationMs: 1))
        s.apply(.assistantText(messageId: "m", index: 0, delta: "x", final: false, promptId: "p"))
        s.apply(.toolStarted(toolUseId: "t2", name: "Read", input: .null, promptId: "p"))
        XCTAssertEqual(s.state, .waiting(kind: .permission, requestId: r.id))
    }

    func testClosingOneOfTwoRequestsKeepsWaitingOnTheOther() {
        var s = workingTracker()
        let a = request(), b = request(kind: .question)
        s.apply(.requestOpened(a))
        s.apply(.requestOpened(b))
        XCTAssertEqual(s.state, .waiting(kind: .permission, requestId: a.id))     // the oldest open one
        s.apply(.requestClosed(requestId: a.id, resolution: .answeredInApp))
        XCTAssertEqual(s.state, .waiting(kind: .question, requestId: b.id))
        s.apply(.requestClosed(requestId: b.id, resolution: .answeredInApp))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testTurnEndAndExitForgetOpenRequests() {
        var s = workingTracker()
        s.apply(.requestOpened(request()))
        s.apply(.turnEnded(promptId: "p", lastMessage: nil))
        XCTAssertEqual(s.state, .ready)
        s.apply(.userMessage(text: "again", promptId: "p2", origin: .chat))
        XCTAssertEqual(s.state, .working(.thinking))
        s.apply(.requestOpened(request()))
        s.processExited(reason: "boom", retryAt: nil)
        s.processStarted()
        s.sessionStarted()
        s.apply(.userMessage(text: "third", promptId: "p3", origin: .chat))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testRequestClosedWhileNotWaitingKeepsState() {
        var s = workingTracker()
        s.apply(.requestClosed(requestId: UUID(), resolution: .cancelled))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testTurnEndedGoesReady() {
        var s = workingTracker()
        s.apply(.turnEnded(promptId: "p", lastMessage: "ok"))
        XCTAssertEqual(s.state, .ready)
    }

    func testTurnFailedGoesReady() {
        var s = workingTracker()
        s.apply(.turnFailed(reason: "api error"))
        XCTAssertEqual(s.state, .ready)
    }

    func testTurnInterruptedGoesReady() {
        var s = workingTracker()
        s.apply(.turnInterrupted)
        XCTAssertEqual(s.state, .ready)
    }

    func testSubagentKeepsState() {
        var s = workingTracker()
        s.apply(.subagent(started: true, agentType: "Explore"))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testSystemKeepsState() {
        var s = readyTracker()
        s.apply(.system(.resumed))
        XCTAssertEqual(s.state, .ready)
    }

    func testAssistantTextReplacedKeepsState() {
        var s = workingTracker()
        s.apply(.assistantTextReplaced(messageId: "m", text: "fixed"))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    func testRateLimitedIgnoresEventsExceptUserMessage() {
        var s = workingTracker()
        s.rateLimited(until: until)
        s.apply(.assistantText(messageId: "m", index: 0, delta: "x", final: false, promptId: "p"))
        s.apply(.toolStarted(toolUseId: "t1", name: "Bash", input: .null, promptId: "p"))
        s.apply(.requestOpened(request()))
        s.apply(.turnEnded(promptId: "p", lastMessage: nil))
        s.apply(.turnFailed(reason: "x"))
        XCTAssertEqual(s.state, .rateLimited(until: until))
    }

    func testRateLimitedLeavesOnUserMessage() {
        var s = workingTracker()
        s.rateLimited(until: until)
        s.apply(.userMessage(text: "again", promptId: "p2", origin: .chat))
        XCTAssertEqual(s.state, .working(.thinking))
    }

    // MARK: - Unread

    private func record(_ seq: Int, _ event: ChatEvent) -> ChatEventRecord {
        ChatEventRecord(seq: seq, at: Date(), event: event)
    }

    func testUnreadOnlyAfterTurnEnd() {
        let recs = [record(1, .userMessage(text: "a", promptId: nil, origin: .chat)),
                    record(2, .turnEnded(promptId: nil, lastMessage: nil))]
        XCTAssertTrue(isUnread(lastReadSeq: 1, records: recs))
        XCTAssertFalse(isUnread(lastReadSeq: 2, records: recs))
    }

    func testUnreadAfterTurnFailed() {
        let recs = [record(1, .turnFailed(reason: "x"))]
        XCTAssertTrue(isUnread(lastReadSeq: 0, records: recs))
        XCTAssertFalse(isUnread(lastReadSeq: 1, records: recs))
    }

    func testUnreadAfterTurnInterrupted() {
        let recs = [record(1, .turnInterrupted)]
        XCTAssertTrue(isUnread(lastReadSeq: 0, records: recs))
        XCTAssertFalse(isUnread(lastReadSeq: 1, records: recs))
    }

    func testNotUnreadWithoutTurnEnd() {
        let recs = [record(1, .userMessage(text: "a", promptId: nil, origin: .chat)),
                    record(2, .assistantText(messageId: "m", index: 0, delta: "b", final: true, promptId: nil))]
        XCTAssertFalse(isUnread(lastReadSeq: 0, records: recs))
    }

    func testATurnTheMailStartedIsNotUnread() {
        // Spec §6: the bots' traffic is nothing for the user to read; the user's next turn is.
        let recs = [record(1, .userMessage(text: "Task #1 from Cody", promptId: "p1", origin: .bot)),
                    record(2, .turnEnded(promptId: "p1", lastMessage: "done")),
                    record(3, .userMessage(text: "hi", promptId: "p2", origin: .chat)),
                    record(4, .turnEnded(promptId: "p2", lastMessage: "hello"))]
        XCTAssertFalse(isUnread(lastReadSeq: 0, records: Array(recs.prefix(2))))
        XCTAssertTrue(isUnread(lastReadSeq: 2, records: recs))
        XCTAssertFalse(isUnread(lastReadSeq: 4, records: recs))
    }

    func testNotUnreadWhenNoRecords() {
        XCTAssertFalse(isUnread(lastReadSeq: 0, records: []))
    }

    func testMailAndTasksLeaveTheStateAlone() {
        var s = readyTracker()
        s.apply(.task(TaskCard(number: 1, from: "A", to: "B", text: "x", deadline: Date(), status: .open)))
        s.apply(.mail(MailNote(messageId: UUID(), kind: .note, from: "A", to: "B", direction: .sent, text: "x")))
        XCTAssertEqual(s.state, .ready)
    }

    func testAStepClosingAfterItsTurnLeavesTheBotReady() {
        // Codex: a command an interruption left running ends after its turn (spec §3.3).
        var s = workingTracker()
        s.apply(.toolStarted(toolUseId: "t1", name: "Bash", input: .null, promptId: "p"))
        s.apply(.turnInterrupted)
        s.apply(.toolFinished(toolUseId: "t1", ok: true, output: "", durationMs: 30_000))
        XCTAssertEqual(s.state, .ready)
    }
}
