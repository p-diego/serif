import XCTest
@testable import SerifCore

final class SerifToolsTests: XCTestCase {
    private func reply(_ line: String, call: (String, JSONValue) -> ToolResult = { _, _ in ToolResult("-") }) -> JSONValue? {
        mcpReply(to: Data(line.utf8), call: call).flatMap { try? JSONValue.parse(Data($0.utf8)) }
    }

    func testInitializeNamesTheServerAndExplainsTheTools() {
        let r = reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(r?["id"], 1)
        XCTAssertEqual(r?["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(r?["result"]?["capabilities"], ["tools": [:]])
        XCTAssertEqual(r?["result"]?["serverInfo"]?["name"], "serif")
        XCTAssertEqual(r?["result"]?["instructions"]?.string, serifToolsGuide)
        // A version it does not know gets its newest.
        let newer = reply(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(newer?["result"]?["protocolVersion"], "2025-06-18")
    }

    func testEightTools() {
        let tools = reply(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)?["result"]?["tools"]?.array ?? []
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["send_message", "complete_task", "cancel_task", "check_inbox",
                                                                 "list_bots", "create_bot", "update_instructions", "archive_bot"])
        let send = tools[0]["inputSchema"]
        XCTAssertEqual(send?["required"], ["to", "body", "kind"])
        XCTAssertEqual(send?["properties"]?["kind"]?["enum"], ["task", "reply", "note"])
        XCTAssertEqual(send?["properties"]?["deadline_hours"]?["maximum"], 168)
        for tool in tools { XCTAssertEqual(tool["inputSchema"]?["type"], "object") }
    }

    func testACallGoesThroughAndComesBackAsText() {
        var asked: (String, JSONValue)?
        let r = reply(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_bots","arguments":{"x":1}}}"#) {
            asked = ($0, $1)
            return ToolResult("no such bot", isError: true)
        }
        XCTAssertEqual(asked?.0, "list_bots")
        XCTAssertEqual(asked?.1, ["x": 1])
        XCTAssertEqual(r?["result"], ["content": [["type": "text", "text": "no such bot"]], "isError": true])
    }

    func testNotificationsPingAndTheRest() {
        XCTAssertNil(mcpReply(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) { _, _ in .unreachable })
        XCTAssertEqual(reply(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?["result"], [:])
        XCTAssertEqual(reply(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)?["error"]?["code"], -32601)
        XCTAssertEqual(reply("not json")?["error"]?["code"], -32700)
        XCTAssertFalse(mcpReply(to: Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#.utf8)) { _, _ in .unreachable }!
            .contains("\n"))                                                          // one line per message
    }
}
