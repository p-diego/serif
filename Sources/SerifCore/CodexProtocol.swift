import Foundation

/// One JSON-RPC message from a Codex app-server (spec §4): a notification, a request it makes of every client (approvals,
/// questions), or the answer to one of the engine's requests, whose ids are numbers.
public enum CodexMessage: Equatable, Sendable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
    case response(id: Int, result: JSONValue)
    case failure(id: Int, message: String)

    /// Nil for anything that is not a JSON-RPC message.
    public init?(_ data: Data) {
        guard let v = try? JSONValue.parse(data), v.object != nil else { return nil }
        let params = v["params"] ?? [:]
        switch (v["id"], v["method"]?.string) {
        case let (id?, method?): self = .request(id: id, method: method, params: params)
        case let (nil, method?): self = .notification(method: method, params: params)
        case let (id?, nil):
            guard let n = id.int else { return nil }
            if let error = v["error"] { self = .failure(id: n, message: error["message"]?.string ?? error.compactText) }
            else { self = .response(id: n, result: v["result"] ?? .null) }
        default: return nil
        }
    }
}

/// The frames the engine sends: a request (its id comes back with the answer), a notification, the answer to a server
/// request (with that request's id), or an error in its place. Codex's JSON-RPC has no "jsonrpc" member (seen 12/10).
public func codexRequest(id: Int, method: String, params: JSONValue) -> String {
    frame(["id": .number(Double(id)), "method": .string(method), "params": params])
}
public func codexNotification(method: String, params: JSONValue) -> String { frame(["method": .string(method), "params": params]) }
public func codexResponse(id: JSONValue, result: JSONValue) -> String { frame(["id": id, "result": result]) }
public func codexErrorResponse(id: JSONValue, message: String) -> String {
    frame(["id": id, "error": ["code": -32601, "message": .string(message)]])
}
private func frame(_ value: JSONValue) -> String { value.compactText }

/// Texts the engine gives in English; the app shows them translated (spec §8).
public enum CodexText {
    public static let isolation = "Isolation not guaranteed"
    public static let notStarted = "Codex did not start in time"
    public static let terminalNotYet = "The terminal opens after the first message"
}

/// Why a Codex bot must not run, from what its thread reports right after it opens (spec §4, §8): Siigil's hooks on
/// (`experimentalFeature/list`), or the account's connectors there while the bot has them off (`mcpServerStatus/list`).
/// Nil when isolated; a missing answer is never taken as isolated.
public func codexIsolationProblem(features: JSONValue?, mcpServers: JSONValue?, connectors: Bool) -> String? {
    let hooks = features?["data"]?.array?.first { $0["name"]?.string == "hooks" }
    guard hooks?["enabled"]?.bool == false else { return "hooks are not off" }
    guard !connectors else { return nil }
    guard let servers = mcpServers?["data"]?.array else { return "the connectors could not be checked" }
    return servers.contains { $0["name"]?.string == "codex_apps" } ? "the account's connectors are on" : nil
}

/// A Codex model a bot can run (`model/list`).
public struct CodexModel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public init(id: String, name: String, isDefault: Bool) { self.id = id; self.name = name; self.isDefault = isDefault }
}

/// What Codex offers a bot (spec §6), from a short-lived server of the engine's: the installed plugins, which of them are
/// the account's remote ones (they cannot be turned off, only their skills hidden) with those skills' names, and the
/// models.
public struct CodexCatalog: Codable, Equatable, Sendable {
    public var plugins: [CatalogItem]
    public var remotePlugins: [String]
    public var remoteSkills: [String: [String]]
    public var models: [CodexModel]

    public init(plugins: [CatalogItem] = [], remotePlugins: [String] = [], remoteSkills: [String: [String]] = [:], models: [CodexModel] = []) {
        self.plugins = plugins; self.remotePlugins = remotePlugins; self.remoteSkills = remoteSkills; self.models = models
    }

    /// From the answers to `plugin/list`, `skills/list` and `model/list`: installed plugins by name, visible models with
    /// the default first.
    public init(pluginList: JSONValue?, skillList: JSONValue?, modelList: JSONValue?) {
        var plugins: [CatalogItem] = [], remote: [String] = []
        for market in pluginList?["marketplaces"]?.array ?? [] {
            for p in market["plugins"]?.array ?? [] where p["installed"]?.bool == true {
                guard let id = p["id"]?.string else { continue }
                plugins.append(CatalogItem(id: id, name: p["interface"]?["displayName"]?.string ?? p["name"]?.string ?? id,
                                           description: p["interface"]?["shortDescription"]?.string ?? "",
                                           path: p["source"]?["path"]?.string ?? ""))
                if p["source"]?["type"]?.string == "remote" { remote.append(id) }
            }
        }
        var skills: [String: [String]] = [:]
        for block in skillList?["data"]?.array ?? [] {
            for s in block["skills"]?.array ?? [] {
                guard let plugin = s["pluginId"]?.string, remote.contains(plugin), let name = s["name"]?.string,
                      !(skills[plugin]?.contains(name) ?? false) else { continue }
                skills[plugin, default: []].append(name)
            }
        }
        let models = (modelList?["data"]?.array ?? []).filter { $0["hidden"]?.bool != true }.compactMap { m -> CodexModel? in
            guard let id = m["id"]?.string else { return nil }
            return CodexModel(id: id, name: m["displayName"]?.string ?? id, isDefault: m["isDefault"]?.bool ?? false)
        }
        self.init(plugins: plugins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                  remotePlugins: remote, remoteSkills: skills,
                  models: models.filter(\.isDefault) + models.filter { !$0.isDefault })
    }
}
