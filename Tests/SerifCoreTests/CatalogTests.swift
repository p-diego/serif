import XCTest
@testable import SerifCore

final class CatalogTests: XCTestCase {
    private var root: URL!

    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("serif-catalog-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testSkillsFromOwnAndSyncedFolders() throws {
        try write("---\nname: docx\ndescription: \"Word documents\"\nlicense: x\n---\n# Docx\n", "skills/synced/acc/docx/SKILL.md")
        try write("---\nname: tidy\ndescription: >\n  Keeps things\n  tidy.\n---\n", "skills/tidy/SKILL.md")
        try write("no front matter\n", "skills/bare/SKILL.md")
        try write("---\nname: inner\n---\n", "skills/tidy/examples/SKILL.md")    // inside a skill: not a skill of its own
        let skills = ClaudeCatalog.skills(root: root)
        XCTAssertEqual(skills.map(\.name), ["bare", "docx", "tidy"])
        XCTAssertEqual(skills.map(\.description), ["", "Word documents", "Keeps things tidy."])
        XCTAssertTrue(skills[1].id.hasSuffix("/skills/synced/acc/docx"))
        XCTAssertEqual(skills[1].id, skills[1].path)
    }

    func testPluginsInstalledAndSyncedKeepTheNewestGeneration() throws {
        let installed = root.appendingPathComponent("cache/superpowers/6.4.1").path
        try write(#"{"version":2,"plugins":{"superpowers@official":[{"scope":"user","installPath":"\#(installed)"}],"#
                  + #""gone@official":[{"scope":"user","installPath":"/nowhere/at/all"}]}}"#, "plugins/installed_plugins.json")
        try write(#"{"name":"superpowers","description":"Core skills"}"#, "cache/superpowers/6.4.1/.claude-plugin/plugin.json")
        try write(#"{"name":"figma","description":"old"}"#, "plugins/synced/acc/figma/.claude-plugin/plugin.json")
        try write(#"{"name":"figma","description":"new"}"#, "plugins/synced/acc/figma~g2/.claude-plugin/plugin.json")
        try write("{}", "plugins/synced/acc/figma~g2.meta.json")
        try write(#"{"name":"hidden"}"#, "plugins/synced/.bucket-acc/hidden/.claude-plugin/plugin.json")
        let plugins = ClaudeCatalog.plugins(root: root)
        XCTAssertEqual(plugins.map(\.id), ["figma", "superpowers@official"])     // "gone": its folder is not there
        XCTAssertEqual(plugins.map(\.description), ["new", "Core skills"])
        XCTAssertTrue(plugins[0].path.hasSuffix("/figma~g2"))
        XCTAssertEqual(plugins[1].path, installed)
        XCTAssertEqual(plugins[1].name, "superpowers")
    }

    func testPluginFoldersSkipMissingAndDuplicates() {
        let items = [CatalogItem(id: "a@m", name: "a", description: "", path: "/p/a"),
                     CatalogItem(id: "b", name: "b", description: "", path: "/p/b")]
        let resolved = ClaudeCatalog.pluginFolders(["a@m", "x@m", "b", "a@m"], in: items)
        XCTAssertEqual(resolved.folders, ["/p/a", "/p/b"])
        XCTAssertEqual(resolved.missing, ["x@m"])
    }

    func testNoClaudeFolderGivesAnEmptyCatalog() {
        XCTAssertEqual(ClaudeCatalog(root: root), ClaudeCatalog())
    }

    func testConfigRoot() {
        XCTAssertEqual(claudeConfigRoot(environment: ["CLAUDE_CONFIG_DIR": "/tmp/c"]).path, "/tmp/c")
        XCTAssertEqual(claudeConfigRoot(environment: [:]).path, NSHomeDirectory() + "/.claude")
    }
}
