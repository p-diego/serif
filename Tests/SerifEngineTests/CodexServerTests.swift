import XCTest
import SerifCore
@testable import SerifEngine

/// The engine's side of a Codex app-server (spec §4), against fake-codex.
final class CodexServerTests: XCTestCase {
    private let queue = DispatchQueue(label: "codex-server-test")
    private var root: URL!
    private var server: CodexServer!
    private var fake: String { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fake-codex").path }
    private var launches: String { root.path + "/launches.jsonl" }
    private var received: String { root.path + "/rpc.jsonl" }

    override func setUp() {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("serif-codex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = CodexServer(queue: queue)
    }

    override func tearDown() {
        let stopped = expectation(description: "stopped")
        queue.async { self.server.stop { stopped.fulfill() } }
        wait(for: [stopped], timeout: 5)
        try? FileManager.default.removeItem(at: root)
    }

    /// How to start fake-codex on `scenario`.
    private func launch(_ scenario: String, env extra: [String: String] = [:], token: String = codexToken()) -> CodexServer.Launch {
        let path = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/scenarios/\(scenario).jsonl").path
        let env = ["SERIF_FAKE_CODEX_SCENARIO": path, "SERIF_FAKE_LOG": launches, "SERIF_FAKE_CODEX_RPC": received].merging(extra) { $1 }
        return CodexServer.Launch(executable: fake, args: { codexServerArgs(listen: "ws://127.0.0.1:\($0)", tokenHash: codexTokenHash(token)) },
                                  environment: env, cwd: root.path, token: token, log: root.appendingPathComponent("codex.log"))
    }

    /// Starts fake-codex on `scenario`; returns why it could not start, if so.
    private func start(_ scenario: String, env extra: [String: String] = [:], token: String = codexToken()) -> CodexServer.Failure? {
        start(launch(scenario, env: extra, token: token))
    }

    private func start(_ launch: CodexServer.Launch) -> CodexServer.Failure? {
        let started = expectation(description: "started")
        var failure: CodexServer.Failure?
        queue.async { self.server.start(launch) { failure = $0; started.fulfill() } }
        wait(for: [started], timeout: 10)
        return failure
    }

    private func lines(_ path: String) -> [JSONValue] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
    }

    func testTalksJSONRPCWithItsSecretAndReportsItsExit() throws {
        let token = codexToken()
        XCTAssertNil(start("codex-server", token: token))
        // Only the hash on the command line; the handshake of spec §4.
        let args = try XCTUnwrap(lines(launches).first?["args"]?.array).compactMap(\.string)
        XCTAssertEqual(args[args.firstIndex(of: "--ws-token-sha256")! + 1], codexTokenHash(token))
        XCTAssertFalse(args.contains(token))
        XCTAssertEqual(lines(received).prefix(2).map { $0["method"] }, ["initialize", "initialized"])
        XCTAssertEqual(lines(received).first?["params"]?["capabilities"]?["experimentalApi"], true)

        var messages: [CodexMessage] = []
        var answer: Result<JSONValue, CodexServer.Failure>?
        var code: Int32?
        let asked = expectation(description: "server request"), exited = expectation(description: "exit")
        queue.sync {
            server.onMessage = { messages.append($0); if case .request = $0 { asked.fulfill() } }
            server.onExit = { code = $0; exited.fulfill() }
            server.request("turn/start", ["threadId": "thr-1", "input": [["type": "text", "text": "hi"]]]) { answer = $0 }
        }
        wait(for: [asked], timeout: 5)
        XCTAssertEqual(try queue.sync { try answer?.get() }, ["turn": ["id": "turn-1", "status": "inProgress"]])
        XCTAssertEqual(queue.sync { messages.first }, .notification(method: "turn/started", params: ["threadId": "thr-1", "turn": ["id": "turn-1", "status": "inProgress"]]))
        queue.sync { server.respond(to: 0, result: ["decision": "accept"]) }
        wait(for: [exited], timeout: 5)                      // the scenario exits after the answer: reported as the exit it is
        XCTAssertEqual(code, 3)
        XCTAssertTrue(lines(received).contains(["id": 0, "result": ["decision": "accept"]]))
        XCTAssertEqual(queue.sync { messages.last }, .notification(method: "serverRequest/resolved", params: ["threadId": "thr-1", "requestId": 0]))
    }

    func testErrorsComeBackFromCodex() {
        XCTAssertNil(start("codex-server"))
        var failure: CodexServer.Failure?
        let answered = expectation(description: "answered")
        queue.sync { server.request("no/such", [:]) { if case let .failure(f) = $0 { failure = f }; answered.fulfill() } }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(failure?.message, "unknown method no/such")
        XCTAssertEqual(failure?.fromCodex, true)
    }

    func testSlowStartAndTakenPortAreWaitedFor() {
        // Review Focus 3: the first server finds its port taken and exits; the second answers a second late.
        let busy = root.path + "/busy"
        FileManager.default.createFile(atPath: busy, contents: nil)
        XCTAssertNil(start("codex-server", env: ["SERIF_FAKE_CODEX_BUSY": busy, "SERIF_FAKE_CODEX_DELAY": "1"]))
        let ports = lines(launches).compactMap { $0["args"]?.array?[2].string }
        XCTAssertEqual(ports.count, 2)
        XCTAssertNotEqual(ports[0], ports[1])
    }

    func testStopIsNotAnExit() {
        XCTAssertNil(start("codex-server"))
        var exits = 0
        let stopped = expectation(description: "stopped")
        queue.sync { server.onExit = { _ in exits += 1 }; server.stop { stopped.fulfill() } }
        wait(for: [stopped], timeout: 5)
        XCTAssertEqual(queue.sync { exits }, 0)
        XCTAssertFalse(queue.sync { server.isRunning })
    }

    func testARefusedHandshakeIsNotRetried() {
        // Another Codex version refusing Serif (spec §8): its message, and no new connections.
        let failure = start("codex-refused")
        XCTAssertEqual(failure?.message, "unsupported client")
        XCTAssertEqual(failure?.fromCodex, true)
        Thread.sleep(forTimeInterval: 0.6)          // a retry would have sent a second initialize by now
        XCTAssertEqual(lines(received).filter { $0["method"] == "initialize" }.count, 1)
    }

    func testAServerThatKeepsExitingGivesUpAfterThreeSpawns() {
        let log = launches
        let failure = start(CodexServer.Launch(executable: "/bin/sh", args: { ["-c", "echo \($0) >> '\(log)'; exit 1"] }, environment: [:],
                                               cwd: root.path, token: codexToken(), log: root.appendingPathComponent("codex.log")))
        XCTAssertEqual(failure?.message, "Codex exited at start (code 1)")
        XCTAssertEqual(failure?.fromCodex, false)
        XCTAssertEqual(((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").count, 3)
    }

    func testStopEndsAStartInProgress() {
        var calls = 0
        let slow = launch("codex-server", env: ["SERIF_FAKE_CODEX_DELAY": "3"])
        queue.async { self.server.start(slow) { _ in calls += 1 } }
        Thread.sleep(forTimeInterval: 0.3)
        let stopped = expectation(description: "stopped")
        queue.async { self.server.stop { stopped.fulfill() } }
        wait(for: [stopped], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)          // a retry or a new launch would have come by now
        XCTAssertEqual(queue.sync { calls }, 0)
        XCTAssertEqual(lines(launches).count, 1)
        XCTAssertFalse(queue.sync { server.isRunning })
    }
}
