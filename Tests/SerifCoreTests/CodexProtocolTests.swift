import XCTest
@testable import SerifCore

final class CodexProtocolTests: XCTestCase {
    private func message(_ json: String) -> CodexMessage? { CodexMessage(Data(json.utf8)) }

    func testMessages() {
        XCTAssertEqual(message(#"{"method":"turn/started","params":{"threadId":"t"}}"#), .notification(method: "turn/started", params: ["threadId": "t"]))
        XCTAssertEqual(message(#"{"id":0,"method":"item/commandExecution/requestApproval","params":{}}"#),
                       .request(id: 0, method: "item/commandExecution/requestApproval", params: [:]))
        XCTAssertEqual(message(#"{"id":4,"result":{"thread":{"id":"t"}}}"#), .response(id: 4, result: ["thread": ["id": "t"]]))
        XCTAssertEqual(message(#"{"id":5,"error":{"code":-32600,"message":"unknown method"}}"#), .failure(id: 5, message: "unknown method"))
        XCTAssertNil(message("not json"))
        XCTAssertNil(message("[1,2]"))
    }

    func testFramesRoundTrip() throws {
        XCTAssertEqual(message(codexRequest(id: 3, method: "turn/start", params: ["input": [["type": "text", "text": "ciao"]]])),
                       .request(id: 3, method: "turn/start", params: ["input": [["type": "text", "text": "ciao"]]]))
        // Without a "jsonrpc" member, like Codex's own (seen 12/10).
        XCTAssertEqual(codexResponse(id: 0, result: ["decision": "accept"]), #"{"id":0,"result":{"decision":"accept"}}"#)
        XCTAssertEqual(codexNotification(method: "initialized", params: [:]), #"{"method":"initialized","params":{}}"#)
        XCTAssertEqual(try JSONValue.parse(Data(codexErrorResponse(id: 7, message: "no").utf8))["error"]?["message"], "no")
    }

    // Answers recorded 13/10 (r9): hooks off and codex_apps gone only when the command line says so.
    func testIsolation() {
        let hooksOff: JSONValue = ["data": [["name": "hooks", "enabled": false], ["name": "apps", "enabled": false]]]
        let hooksOn: JSONValue = ["data": [["name": "hooks", "enabled": true]]]
        let noApps: JSONValue = ["data": [["name": "cua_repl"], ["name": "node_repl"]]]
        let apps: JSONValue = ["data": [["name": "codex_apps"], ["name": "cua_repl"]]]
        XCTAssertNil(codexIsolationProblem(features: hooksOff, mcpServers: noApps, connectors: false))
        XCTAssertNil(codexIsolationProblem(features: hooksOff, mcpServers: nil, connectors: true))     // connectors on: not asked
        XCTAssertNotNil(codexIsolationProblem(features: hooksOn, mcpServers: noApps, connectors: false))
        XCTAssertNotNil(codexIsolationProblem(features: ["data": []], mcpServers: noApps, connectors: false))   // not listed: not shown off
        XCTAssertNotNil(codexIsolationProblem(features: nil, mcpServers: noApps, connectors: false))
        XCTAssertNotNil(codexIsolationProblem(features: hooksOff, mcpServers: apps, connectors: false))
        XCTAssertNotNil(codexIsolationProblem(features: hooksOff, mcpServers: nil, connectors: false))
        // A first page only: codex_apps may be on the next one, so it is not shown gone.
        XCTAssertNotNil(codexIsolationProblem(features: hooksOff, mcpServers: ["data": [], "nextCursor": "2"], connectors: false))
        XCTAssertNil(codexIsolationProblem(features: hooksOff, mcpServers: ["data": [], "nextCursor": .null], connectors: false))
    }

    func testCatalogFromCodex() throws {
        let answers = try JSONValue.parse(Data(try fixture("codex-catalog.json").utf8))
        let catalog = CodexCatalog(pluginList: answers["pluginList"], skillList: answers["skillList"], modelList: answers["modelList"])
        XCTAssertEqual(catalog.plugins.count, 13)
        XCTAssertEqual(Array(catalog.plugins.map(\.name).prefix(5)), ["browser", "code-review", "codex-app-tools", "computer-use", "Documents"])
        let documents = try XCTUnwrap(catalog.plugins.first { $0.id == "documents@openai-primary-runtime" })
        XCTAssertEqual(documents.description, "Create and edit documents")
        XCTAssertEqual(catalog.remotePlugins, ["plugin-management@openai-curated-remote", "work-pets@openai-curated-remote"])
        XCTAssertEqual(catalog.remoteSkills, ["plugin-management@openai-curated-remote": ["plugin-management:plugin-management"],
                                              "work-pets@openai-curated-remote": ["work-pets:create-pet", "work-pets:pets", "work-pets:update-pet"]])
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-6-luna", "gpt-5.6-terra", "gpt-5.6-luna"])
        XCTAssertTrue(catalog.models[0].isDefault)
    }

    func testCatalogLeavesOutWhatIsNotInstalledOrHidden() {
        let plugins: JSONValue = ["marketplaces": [["name": "m", "plugins": [
            ["id": "a@m", "name": "a", "installed": true, "source": ["type": "local", "path": "/a"]],
            ["id": "b@m", "name": "b", "installed": false, "source": ["type": "local", "path": "/b"]]]]]]
        let models: JSONValue = ["data": [["id": "x", "displayName": "X", "hidden": false, "isDefault": false],
                                          ["id": "h", "displayName": "H", "hidden": true, "isDefault": false],
                                          ["id": "d", "displayName": "D", "hidden": false, "isDefault": true]]]
        let catalog = CodexCatalog(pluginList: plugins, skillList: nil, modelList: models)
        XCTAssertEqual(catalog.plugins.map(\.id), ["a@m"])
        XCTAssertEqual(catalog.plugins.first?.path, "/a")
        XCTAssertEqual(catalog.models.map(\.id), ["d", "x"])                 // the default first, hidden ones left out
        XCTAssertEqual(CodexCatalog(pluginList: nil, skillList: nil, modelList: nil), CodexCatalog())
    }

    func testCatalogTravelsToTheApp() throws {
        let catalog = CodexCatalog(plugins: [CatalogItem(id: "a@m", name: "A", description: "", path: "/a")], remotePlugins: ["r@m"],
                                   remoteSkills: ["r@m": ["r:s"]], models: [CodexModel(id: "d", name: "D", isDefault: true)])
        let data = try protocolEncoder().encode(ResponseBody.codexCatalog(catalog))
        XCTAssertEqual(try protocolDecoder().decode(ResponseBody.self, from: data), .codexCatalog(catalog))
        let request = try protocolEncoder().encode(AppRequest.codexCatalog)
        XCTAssertEqual(try protocolDecoder().decode(AppRequest.self, from: request), .codexCatalog)
    }
}
