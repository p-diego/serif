import XCTest
@testable import SerifCore

final class LineSocketTests: XCTestCase {
    let queue = DispatchQueue(label: "linesocket.test")
    var path = ""

    override func setUp() {
        path = "/tmp/serif-test-\(UUID().uuidString.prefix(8)).sock"
    }
    override func tearDown() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "socket file left behind")
        unlink(path)
    }

    /// Echo server; the returned array keeps accepted connections alive for the test.
    func makeEcho() throws -> LineServer {
        try LineServer(path: path, queue: queue) { conn in
            conn.onLine = { [weak conn] line in conn?.send(line) }
        }
    }

    func testEchoRoundTrip1000Lines() throws {
        let server = try makeEcho()
        let done = expectation(description: "1000 echoes")
        var got: [String] = []
        let client = try XCTUnwrap(LineClient.connect(path: path, queue: queue))
        client.onLine = { line in
            got.append(String(decoding: line, as: UTF8.self))
            if got.count == 1000 { done.fulfill() }
        }
        queue.sync { for i in 0..<1000 { client.send(Data("line \(i)".utf8)) } }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(got, (0..<1000).map { "line \($0)" })
        queue.sync { client.close(); server.close() }
    }

    func testFiveMegabyteLineArrivesIntact() throws {
        let server = try makeEcho()
        let done = expectation(description: "big echo")
        let payload = Data((0..<(5 * 1024 * 1024)).map { UInt8(ascii: "a") + UInt8($0 % 26) })
        var got: Data?
        let client = try XCTUnwrap(LineClient.connect(path: path, queue: queue))
        client.onLine = { got = $0; done.fulfill() }
        queue.sync { client.send(payload) }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(got, payload)
        queue.sync { client.close(); server.close() }
    }

    func testClientGetsOnCloseWhenServerCloses() throws {
        let accepted = expectation(description: "accepted")
        var serverSide: LineConnection?
        let server = try LineServer(path: path, queue: queue) { conn in
            serverSide = conn
            accepted.fulfill()
        }
        let closed = expectation(description: "client closed")
        closed.assertForOverFulfill = true
        let client = try XCTUnwrap(LineClient.connect(path: path, queue: queue))
        client.onClose = { closed.fulfill() }
        wait(for: [accepted], timeout: 5)
        queue.sync { serverSide?.close() }
        wait(for: [closed], timeout: 5)
        queue.sync { client.close(); server.close() }
    }

    func testConnectToMissingPathReturnsNil() {
        XCTAssertNil(LineClient.connect(path: path, queue: queue))
    }

    func testPathTooLongThrows() {
        let long = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertThrowsError(try LineServer(path: long, queue: queue) { _ in })
        XCTAssertNil(LineClient.connect(path: long, queue: queue))
    }

    func testRequestTimesOutOnSilentServer() throws {
        let server = try LineServer(path: path, queue: queue) { _ in }
        let start = Date()
        let reply = LineClient.request(path: path, line: Data("hi".utf8), timeout: 0.5)
        XCTAssertNil(reply)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        queue.sync { server.close() }
    }

    func testRequestGetsReply() throws {
        let server = try makeEcho()
        XCTAssertEqual(LineClient.request(path: path, line: Data("ping".utf8), timeout: 2), Data("ping".utf8))
        queue.sync { server.close() }
    }

    func testServerCloseUnlinksFile() throws {
        let server = try makeEcho()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        queue.sync { server.close() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
