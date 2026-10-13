import XCTest
import SerifCore
@testable import SerifEngine

final class BackoffTests: XCTestCase {
    func testSequenceAndReset() {
        var b = Backoff()
        let seq = (0..<10).map { _ in b.nextDelay(ranFor: 1) }
        XCTAssertEqual(seq, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        XCTAssertEqual(b.nextDelay(ranFor: 60), 2)
        XCTAssertEqual(b.nextDelay(ranFor: 1), 4)
    }
}

final class BotHostTests: XCTestCase {
    final class Delegate: BotHostDelegate {
        var output = Data()
        var signals: [Set<ScreenSignal>] = []
        var exitCode: Int32??
        var onOutput: (() -> Void)?
        var onExit: (() -> Void)?
        var onStarted: (() -> Void)?
        var onSignals: ((BotHost, Set<ScreenSignal>) -> Void)?
        func botHost(_ host: BotHost, output data: Data, seq: Int) { output.append(data); onOutput?() }
        func botHost(_ host: BotHost, screen signals: Set<ScreenSignal>) { self.signals.append(signals); onSignals?(host, signals) }
        func botHostStarted(_ host: BotHost) { onStarted?() }
        func botHost(_ host: BotHost, exited code: Int32?, ranFor: TimeInterval) { exitCode = .some(code); onExit?() }
    }

    let queue = DispatchQueue(label: "bothost-test")
    let delegate = Delegate()
    lazy var host = BotHost(botId: UUID(), queue: queue, delegate: delegate)

    private var binDir: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }

    private func plan(_ scenario: String) -> LaunchPlan {
        let path = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/scenarios/\(scenario).jsonl").path
        let log = NSTemporaryDirectory() + "fake-\(UUID().uuidString).log"
        return LaunchPlan(executable: binDir.appendingPathComponent("fake-claude").path, args: ["--x"],
                          environment: ["SERIF_FAKE_SCENARIO": path, "SERIF_FAKE_LOG": log,
                                        "SERIF_HOOK_BIN": binDir.appendingPathComponent("serif-hook").path,
                                        "TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
                          cwd: NSTemporaryDirectory())
    }

    /// Waits until `delegate.output` contains `text`.
    private func waitForOutput(_ text: String, timeout: TimeInterval = 5) {
        let e = expectation(description: "output \(text)")
        e.assertForOverFulfill = false
        // Only the tail is searched: decoding all output per chunk is quadratic on the flood test.
        let seen = { [unowned self] in String(decoding: delegate.output.suffix(8192), as: UTF8.self).contains(text) }
        queue.sync {
            delegate.onOutput = { if seen() { e.fulfill() } }
            if seen() { e.fulfill() }
        }
        wait(for: [e], timeout: timeout)
    }

    func testTrustPromptAnsweredByDelegate() {
        queue.sync {
            delegate.onSignals = { host, s in
                if s.contains(.trustPrompt) { host.write(Array("\u{1B}[B".utf8)) }
                if s.contains(.trustConfirm) { host.write([0x0D]) }
            }
            host.start(plan("trust"))
        }
        waitForOutput("READY")
        XCTAssertEqual(delegate.signals.prefix(2), [[.trustPrompt], [.trustConfirm]])
        queue.sync { XCTAssertTrue(host.screenText.contains("READY")) }
        stopHost()
    }

    func testReplayReturnsOutput() {
        queue.sync { host.start(plan("basic")) }
        waitForOutput("READY")
        queue.sync {
            let r = host.replay()
            XCTAssertEqual(String(decoding: r.data, as: UTF8.self), "READY")
            XCTAssertEqual(r.seq, 5)
        }
        stopHost()
    }

    func testTypeMessageIsBracketedPaste() {
        queue.sync { host.start(plan("paste")) }
        waitForOutput("READY")
        queue.sync { host.typeMessage("a\nb") }
        waitForOutput("GOT-PASTE")
        stopHost()
    }

    func testStopExits() {
        queue.sync { host.start(plan("basic")) }
        waitForOutput("READY")
        let e = expectation(description: "stopped")
        let t0 = Date()
        queue.sync { host.stop { e.fulfill() } }
        wait(for: [e], timeout: 3.5)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3.5)
        queue.sync { XCTAssertFalse(host.isRunning) }
        XCTAssertNotNil(delegate.exitCode)
    }

    func testStopFromWorkerThreadUsesSIGTERM() {
        // The engine starts bots from GCD worker threads, whose blocked signals a child would inherit.
        queue.async { self.host.start(self.plan("basic")) }
        waitForOutput("READY")
        let e = expectation(description: "stopped")
        let t0 = Date()
        queue.sync { host.stop { e.fulfill() } }
        wait(for: [e], timeout: 4)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "SIGTERM was ignored: the bot was only killed by SIGKILL")
    }

    func testCrashReportsExitCode() {
        let e = expectation(description: "exited")
        queue.sync {
            delegate.onExit = { e.fulfill() }
            host.start(plan("crash"))
        }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(delegate.exitCode, .some(3))
    }

    func testPermissionScenarioRunsHookBinary() {
        // No engine socket: serif-hook fails open, but the player must keep going and stay alive.
        queue.sync { host.start(plan("permission")) }
        waitForOutput("AFTER-HOOK") // printed only after the hook binary has run and returned
        stopHost()
    }

    func testSeqKeepsGrowingAcrossRestarts() {
        // The app drops output whose seq it has already seen: a restart must not start counting again from 0.
        queue.sync { host.start(plan("basic")) }
        waitForOutput("READY")
        let before = queue.sync { host.replay().seq }
        stopHost()
        queue.sync { delegate.output = Data(); host.start(plan("basic")) }
        waitForOutput("READY")
        queue.sync {
            let r = host.replay()
            XCTAssertGreaterThan(r.seq, before)
            XCTAssertEqual(String(decoding: r.data, as: UTF8.self), "READY")    // the replay holds only the new run
        }
        stopHost()
    }

    /// `data.startIndex == 0`: the ring is trimmed with removeSubrange, which keeps Data's indices zero-based.
    func testReplayRingIsBoundedAndZeroBased() {
        queue.sync { host.start(plan("flood")) }
        waitForOutput("FLOOD-END", timeout: 10)
        queue.sync {
            let r = host.replay()
            XCTAssertEqual(r.data.startIndex, 0)
            XCTAssertEqual(r.data.count, 1 << 20)
            XCTAssertGreaterThan(r.seq, 1_500_000)
        }
        stopHost()
    }

    private func stopHost() {
        let e = expectation(description: "stopped")
        queue.sync { host.stop { e.fulfill() } }
        wait(for: [e], timeout: 4)
    }
}

final class ClaudeLocatorTests: XCTestCase {
    func testOrder() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(ClaudeLocator.find(override: "/o/claude", home: "/h", isExecutable: all, shell: { "/s" }), "/o/claude")
        XCTAssertEqual(ClaudeLocator.find(override: "/o/claude", home: "/h", isExecutable: { $0 != "/o/claude" }, shell: { "/s" }), "/h/.local/bin/claude")
        XCTAssertEqual(ClaudeLocator.find(override: nil, home: "/h", isExecutable: { $0 != "/h/.local/bin/claude" }, shell: { "/s" }), "/opt/homebrew/bin/claude")
        XCTAssertEqual(ClaudeLocator.find(override: nil, home: "/h", isExecutable: { $0 == "/s" }, shell: { "/s" }), "/s")
        XCTAssertNil(ClaudeLocator.find(override: nil, home: "/h", isExecutable: { _ in false }, shell: { "/s" }))
        XCTAssertNil(ClaudeLocator.find(override: nil, home: "/h", isExecutable: { $0 == "rel" }, shell: { "rel" }))
    }
}
