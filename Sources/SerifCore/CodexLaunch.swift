import Foundation
import CryptoKit

extension Freedom {
    /// Codex's approval policy for this freedom (spec §5). Asks permission is `untrusted`: Codex itself stops every command
    /// it doesn't know as harmless (some reads too) and the chat shows the card. With `on-request` the model decides, and
    /// live on 14/10 it never asked: a write simply failed in a read-only sandbox. Every freedom writes only in the bot's
    /// folders (workspace-write).
    public var codexApproval: String {
        switch self { case .ask: "untrusted"; case .edits: "on-request"; case .auto: "never" }
    }
}

/// A new secret for one launch of a Codex server: 32 random bytes as hex. It stays in the engine and the bot's terminal.
public func codexToken() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }

/// What the server gets instead of the secret (`--ws-token-sha256`): its SHA-256, hex.
public func codexTokenHash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The arguments of a Codex app-server of Serif's (spec §4, §6): listening on `listen` (a bot's server with its token),
/// with Siigil's hooks and the notify program off for this process; for a bot, Serif's tools (`tools`, the serif-tools
/// executable, spec §4 of 0.5) that never ask and get the bot and its secret by the names of variables in the server's
/// environment, every installed plugin on or off by name (the key without quotes: quoted, Codex ignores it, spec §3.8),
/// the skills of the account's remote plugins it did not choose hidden, and the account's connectors off unless it has
/// them on. Everything that isolates a bot is here, never in a thread's `config`, which would replace it (spec §3.6).
public func codexServerArgs(listen: String, tokenHash: String?, tools: String? = nil,
                            plugins: [(id: String, enabled: Bool)] = [], hiddenSkills: [String] = [],
                            connectors: Bool = true) -> [String] {
    var args = ["app-server", "--listen", listen]
    if let tokenHash { args += ["--ws-auth", "capability-token", "--ws-token-sha256", tokenHash] }
    args += ["--disable", "hooks", "-c", "notify=[]"]
    if let tools {
        args += ["-c", "mcp_servers.serif.command=\(JSONValue.string(tools).compactText)",
                 "-c", "mcp_servers.serif.args=[]",
                 "-c", #"mcp_servers.serif.env_vars=["SERIF_BOT_ID","SERIF_TOKEN","SERIF_HOOK_SOCKET"]"#,
                 // "approve" never asks; "auto" follows the tool's annotations and asked under untrusted (live 15/10).
                 "-c", #"mcp_servers.serif.default_tools_approval_mode="approve""#]
    }
    // ponytail: plugin ids have no dots (Codex 0.160); a dotted one would need a quoted key, which -c ignores.
    for p in plugins { args += ["-c", "plugins.\(p.id).enabled=\(p.enabled)"] }
    if !hiddenSkills.isEmpty {
        let entries = hiddenSkills.map { "{name=\(JSONValue.string($0).compactText),enabled=false}" }
        args += ["-c", "skills.config=[\(entries.joined(separator: ","))]"]
    }
    if !connectors { args += ["--disable", "apps"] }
    return args
}

/// The parameters of `thread/start`, or with `resume` of `thread/resume` (spec §4-5): the bot's folder, model, the same
/// system prompt as a Claude Code bot (memory in AGENTS.md), approval and sandbox from its freedom, and the folders it may
/// write in. Codex forgets the sandbox on resume (spec §3.5): every launch passes everything again. The `config` holds only
/// the writable folders: a `features`, `plugins`, `skills` or `mcp_servers` key there would replace the server's command
/// line and turn Siigil's hooks back on (spec §3.6).
public func codexThreadParams(resume threadId: String?, cwd: String, model: String?, instructions: String,
                              freedom: Freedom, writableRoots: [String]) -> JSONValue {
    var p: [String: JSONValue] = [
        "cwd": .string(cwd),
        "developerInstructions": .string(instructions),
        "approvalPolicy": .string(freedom.codexApproval),
        "sandbox": "workspace-write",
        "config": ["sandbox_workspace_write": ["writable_roots": .array(writableRoots.map(JSONValue.string))]],
    ]
    if let model { p["model"] = .string(model) }
    if let threadId { p["threadId"] = .string(threadId); p["excludeTurns"] = true }    // the chat history is Serif's
    return .object(p)
}

/// The approval and sandbox every `turn/start` passes again (spec §5), the sandbox with the thread's writable folders.
/// Codex keeps a turn's for the turns after it: settings changed in the bot's terminal (/permissions) never reach the chat.
public func codexTurnPolicies(freedom: Freedom, writableRoots: [String]) -> [String: JSONValue] {
    ["approvalPolicy": .string(freedom.codexApproval),
     "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": .array(writableRoots.map(JSONValue.string))]]
}

/// The engine's environment as Codex gets it: the bots' (no `CLAUDE*`, no `ANTHROPIC_API_KEY`) without a
/// `CODEX_THREAD_ID` a Codex session may have left (Gravity drops it too).
public func codexEnvironment(_ base: [String: String]) -> [String: String] {
    var env = botEnvironment(base)
    env["CODEX_THREAD_ID"] = nil
    return env
}

/// Whether a thread's settings (`thread/settings/updated`) leave the bot's freedom (spec §5): another approval policy,
/// another sandbox, network, or a folder to write in that isn't one of the bot's. The terminal's /permissions changes them
/// (live 14/10), and Codex keeps them for the turns after it.
public func codexSettingsDrift(_ settings: JSONValue?, policies: [String: JSONValue]) -> Bool {
    let sandbox = settings?["sandboxPolicy"]
    let roots = Set(policies["sandboxPolicy"]?["writableRoots"]?.array?.compactMap(\.string) ?? [])
    return settings?["approvalPolicy"] != policies["approvalPolicy"] || sandbox?["type"] != policies["sandboxPolicy"]?["type"]
        || sandbox?["networkAccess"] == true
        || !(sandbox?["writableRoots"]?.array ?? []).allSatisfy { $0.string.map(roots.contains) ?? false }
}

/// The bot's real Codex terminal (spec §4): `codex resume` attached to its thread on its server, the secret in the
/// environment (never in the arguments). No approval or sandbox of its own: resuming a remote thread Codex refuses them
/// (live 14/10), and its turns run with the thread's, the bot's (`codexSettingsDrift` watches them).
public func codexTerminalPlan(codexPath: String, threadId: String, port: Int, token: String, cwd: String,
                              baseEnvironment: [String: String]) -> LaunchPlan {
    var env = codexEnvironment(baseEnvironment)
    env["SERIF_CODEX_TOKEN"] = token
    env["TERM"] = "xterm-256color"
    return LaunchPlan(executable: codexPath, args: ["resume", "--remote", "ws://127.0.0.1:\(port)", "--remote-auth-token-env",
                                                    "SERIF_CODEX_TOKEN", "--no-alt-screen", threadId],
                      environment: env, cwd: cwd)
}
