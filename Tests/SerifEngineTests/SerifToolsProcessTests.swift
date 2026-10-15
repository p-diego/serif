import XCTest
import SerifCore

/// serif-tools as an agent runs it, against a stand-in engine (spec §11).
final class SerifToolsProcessTests: XCTestCase {
    private var path = ""
    private var server: LineServer?
    private let queue = DispatchQueue(label: "tools-test-server")
    private let toolsURL = Bundle(for: SerifToolsProcessTests.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("serif-tools")

    override func setUp() { path = "/tmp/st-\(UUID().uuidString.prefix(8)).sock" }
    override func tearDown() { server?.close(); server = nil; unlink(path) }

    /// Runs serif-tools with `lines` on stdin; returns what it printed, one JSON value per line, and the seconds it took.
    private func run(_ lines: [String], env: [String: String]) throws -> ([JSONValue], TimeInterval) {
        let p = Process()
        p.executableURL = toolsURL
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let t0 = Date()
        try p.run()
        inPipe.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (out.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONValue.parse(Data($0)) }, Date().timeIntervalSince(t0))
    }

    private var env: [String: String] { ["SERIF_HOOK_SOCKET": path, "SERIF_BOT_ID": "bot1", "SERIF_TOKEN": "tok1"] }
    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
    private let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"Milo"}}}"#

    func testACallReachesTheEngineAsTheBotWithItsSecret() throws {
        let got = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var line = Data()
        server = try LineServer(path: path, queue: queue) { conn in
            conn.onLine = {
                line = $0
                got.signal()
                conn.send(try! protocolEncoder().encode(HookReply(stdout: #"{"text":"Sent to Milo","isError":false}"#)))
            }
        }
        let (out, _) = try run([initialize, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, call], env: env)
        XCTAssertEqual(got.wait(timeout: .now() + 2), .success)
        let envelope = try protocolDecoder().decode(HookEnvelope.self, from: line)
        XCTAssertEqual(envelope.botId, "bot1")
        XCTAssertEqual(envelope.token, "tok1")
        XCTAssertEqual(envelope.payload, ["tool": "send_message", "arguments": ["to": "Milo"]])
        XCTAssertEqual(out.map { $0["id"] }, [1, 2])                                  // the notification got no answer
        XCTAssertEqual(out.last?["result"], ["content": [["type": "text", "text": "Sent to Milo"]], "isError": false])
    }

    func testNoEngineOrARefusedSecretIsNotReachable() throws {
        let unreachable: JSONValue = ["content": [["type": "text", "text": "Serif is not reachable"]], "isError": true]
        let (alone, seconds) = try run([call], env: env)
        XCTAssertEqual(alone.first?["result"], unreachable)
        XCTAssertLessThan(seconds, 2)
        // The engine drops a call from an unknown bot or an old launch: an empty reply (spec §10).
        server = try LineServer(path: path, queue: queue) { conn in
            conn.onLine = { _ in conn.send(try! protocolEncoder().encode(HookReply(stdout: nil))) }
        }
        XCTAssertEqual(try run([call], env: env).0.first?["result"], unreachable)
        XCTAssertEqual(try run([call], env: [:]).0.first?["result"], unreachable)    // no identity at all
    }
}
