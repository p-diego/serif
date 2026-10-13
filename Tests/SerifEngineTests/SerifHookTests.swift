import XCTest
import SerifCore

final class SerifHookTests: XCTestCase {
    private var path = ""
    private var server: LineServer?
    private let queue = DispatchQueue(label: "hook-test-server")

    override func setUp() { path = "/tmp/sh-\(UUID().uuidString.prefix(8)).sock" }
    override func tearDown() { server?.close(); server = nil; unlink(path) }

    private let hookURL = Bundle(for: SerifHookTests.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("serif-hook")

    /// Runs serif-hook with the given env and stdin; returns (stdout, exit status, seconds).
    private func run(env: [String: String], stdin: String) throws -> (String, Int32, TimeInterval) {
        let p = Process()
        p.executableURL = hookURL
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let t0 = Date()
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), p.terminationStatus, Date().timeIntervalSince(t0))
    }

    private func startServer(reply: String, received: @escaping (Data) -> Void) throws {
        server = try LineServer(path: path, queue: queue) { conn in
            conn.onLine = { line in
                received(line)
                conn.send(Data(reply.utf8))
            }
        }
    }

    private var env: [String: String] {
        ["SERIF_HOOK_SOCKET": path, "SERIF_BOT_ID": "bot1", "SERIF_TOKEN": "tok1"]
    }
    private let payload = #"{"hook_event_name":"Stop","x":1}"#

    func testPrintsEngineReply() throws {
        try startServer(reply: #"{"stdout":"{\"x\":1}"}"#) { _ in }
        let (out, status, _) = try run(env: env, stdin: payload)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "{\"x\":1}\n")
    }

    func testEnvelopeCarriesEnvAndPayload() throws {
        let got = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var line = Data()
        try startServer(reply: "{}") { line = $0; got.signal() }
        _ = try run(env: env, stdin: payload)
        XCTAssertEqual(got.wait(timeout: .now() + 2), .success)
        let e = try protocolDecoder().decode(HookEnvelope.self, from: line)
        XCTAssertEqual(e.botId, "bot1")
        XCTAssertEqual(e.token, "tok1")
        XCTAssertEqual(e.payload["hook_event_name"]?.string, "Stop")
        XCTAssertEqual(e.payload["x"]?.double, 1)
    }

    func testNoServerExitsQuickly() throws {
        let (out, status, secs) = try run(env: env, stdin: payload)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "")
        XCTAssertLessThan(secs, 1)
    }

    func testMissingEnvExitsSilently() throws {
        let (out, status, _) = try run(env: [:], stdin: payload)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "")
    }
}
