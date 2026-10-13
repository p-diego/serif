import XCTest
@testable import SerifCore

final class UpdateTests: XCTestCase {
    // Numbers, not text: 0.10 comes after 0.9. A tag's "v" doesn't count.
    func testNewerComparesNumbersNotText() {
        XCTAssertTrue(isNewer("0.10", than: "0.9"))
        XCTAssertTrue(isNewer("0.12.1", than: "0.12"))
        XCTAssertTrue(isNewer("v0.13", than: "0.12"))
        XCTAssertTrue(isNewer("0.13", than: "v0.12"))
    }

    func testSameOrOlderIsNotNewer() {
        XCTAssertFalse(isNewer("0.12", than: "0.12"))
        XCTAssertFalse(isNewer("v0.12", than: "0.12"))
        XCTAssertFalse(isNewer("0.9", than: "0.10"))
        XCTAssertFalse(isNewer("0.11", than: "0.12"))
    }

    /// releases/latest, cut down to the fields we read.
    private func releaseJSON(tag: String, assets: [String]) -> Data {
        let list = assets.map { #"{"name": "\#($0)", "browser_download_url": "https://github.com/p-diego/serif/releases/download/\#(tag)/\#($0)"}"# }
        return Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/p-diego/serif/releases/tag/\#(tag)", "assets": [\#(list.joined(separator: ","))]}"#.utf8)
    }

    func testParsesTheZipAmongTheAssets() {
        let release = parseRelease(releaseJSON(tag: "v0.2", assets: ["Serif-0.2.dmg", "Serif-0.2.zip"]))
        XCTAssertEqual(release, Release(version: "0.2",
                                        page: URL(string: "https://github.com/p-diego/serif/releases/tag/v0.2")!,
                                        zip: URL(string: "https://github.com/p-diego/serif/releases/download/v0.2/Serif-0.2.zip")!))
    }

    // Without the zip of its own version (only the DMG, or another version's zip) the release is no use.
    func testReleaseWithoutItsZipIsNil() {
        XCTAssertNil(parseRelease(releaseJSON(tag: "v0.2", assets: ["Serif-0.2.dmg"])))
        XCTAssertNil(parseRelease(releaseJSON(tag: "v0.2", assets: ["Serif-0.1.zip"])))
    }

    // Broken, or GitHub's answer while the repo has no release (or is private): 404.
    func testBrokenJSONOrGitHubErrorIsNil() {
        XCTAssertNil(parseRelease(Data("{".utf8)))
        XCTAssertNil(parseRelease(Data(#"{"message": "Not Found", "documentation_url": "https://docs.github.com/rest"}"#.utf8)))
    }

    func testDueAtOnceThenAfterADayOrAnHour() {
        let now = Date()
        XCTAssertTrue(isDue(last: nil, succeeded: false, now: now))
        XCTAssertFalse(isDue(last: now.addingTimeInterval(-23 * 3600), succeeded: true, now: now))
        XCTAssertTrue(isDue(last: now.addingTimeInterval(-24 * 3600), succeeded: true, now: now))
        XCTAssertFalse(isDue(last: now.addingTimeInterval(-59 * 60), succeeded: false, now: now))
        XCTAssertTrue(isDue(last: now.addingTimeInterval(-3600), succeeded: false, now: now))
    }

    // Waits for the app, stops the old engine, restarts the agent, opens the new copy; the path is $0, never in the script.
    func testRelaunchWaitsForTheAppRestartsTheEngineAndSurvivesSpaces() {
        let args = relaunchArguments(pid: 42, uid: 501, app: "/Users/x/My Apps/Serif.app")
        XCTAssertEqual(args, ["-c", """
            while kill -0 42 2>/dev/null; do sleep 0.1; done
            pkill -f "$0/Contents/MacOS/serifd"; while pgrep -f "$0/Contents/MacOS/serifd" >/dev/null; do sleep 0.1; done
            launchctl kickstart -k gui/501/com.serif.engine 2>/dev/null
            open "$0"
            """, "/Users/x/My Apps/Serif.app"])
        XCTAssertFalse(args[1].contains("/Users/x"))
    }

    // Mid-turn bots only (working, or waiting on a request); archived ones never count.
    func testWorkingCountIsBotsMidTurn() {
        let face = BotFace(shape: .allCases[0], body: 0x6BC4A6, eyes: 0x14141A)
        func summary(_ state: BotState, archived: Bool = false) -> BotSummary {
            BotSummary(bot: Bot(projectId: UUID(), name: "B", face: face, archivedAt: archived ? Date() : nil),
                       state: state, unread: false, lastEvent: nil, preview: nil)
        }
        var s = ClientState()
        XCTAssertEqual(s.workingCount, 0)
        for b in [summary(.working(.thinking)), summary(.waiting(kind: .permission, requestId: UUID())), summary(.ready),
                  summary(.stopped), summary(.crashed(reason: "x", retryAt: nil)), summary(.working(.typing), archived: true)] {
            s.bots[b.bot.id] = b
        }
        XCTAssertEqual(s.workingCount, 2)
    }
}
