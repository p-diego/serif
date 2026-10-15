import XCTest
@testable import SerifCore

final class DiagnosticsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_792_000_000)      // 14 Oct 2026, 17:46 UTC

    func testThePageAsPlainText() {
        // Spec §8: everything the window shows, in English like the log; readable when pasted somewhere.
        let d = Diagnostics(
            appVersion: "0.7", engineVersion: "0.7.0", dataFolder: "/data",
            agents: [AgentDiagnostics(agent: .claude, path: "/bin/claude", version: "2.1.296", signedIn: true),
                     AgentDiagnostics(agent: .codex, path: nil, version: nil, signedIn: nil)],
            bots: [BotDiagnostics(name: "Cody", project: "Work", agent: .claude, state: .crashed(reason: "Exit code 3", retryAt: at),
                                  lastCrash: .init(at: at, reason: "Exit code 3"), mailWaiting: 2,
                                  routines: [.init(name: "Tidy", next: at), .init(name: "Off", next: nil)], openCards: 1),
                   BotDiagnostics(name: "Milo", project: "Work", agent: .codex, state: .ready, lastCrash: nil, mailWaiting: 0,
                                  routines: [], openCards: 0)],
            logTail: ["2026-10-14 21:40:00 +0000 bot x: plugin y not found, left out"])
        XCTAssertEqual(diagnosticsText(d, timeZone: TimeZone(identifier: "UTC")!), """
        Serif 0.7 · engine 0.7.0
        Data folder: /data

        Agents
        - Claude Code: /bin/claude, 2.1.296, signed in
        - Codex: not installed

        Bots
        - Cody (Work, Claude Code): crashed: Exit code 3, starting again; mail waiting: 2; open cards: 1; routines: Tidy (next 14 Oct 2026, 17:46), Off (next never)
          last crash: 14 Oct 2026, 17:46 — Exit code 3
        - Milo (Work, Codex): ready; mail waiting: 0; open cards: 0; routines: none

        Log (last 1 lines)
        2026-10-14 21:40:00 +0000 bot x: plugin y not found, left out
        """)
        XCTAssertEqual(stateWord(.working(.thinking)), "working")
        XCTAssertEqual(stateWord(.waiting(kind: .permission, requestId: UUID())), "waiting for the user")
        XCTAssertEqual(stateWord(.crashed(reason: "Codex not installed", retryAt: nil)), "stopped: Codex not installed")
    }
}
