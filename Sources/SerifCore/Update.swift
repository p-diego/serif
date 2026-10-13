import Foundation

// The in-app update, ported from Siigil's (Updater.swift there). `make release` publishes Serif-<version>.zip on tag
// v<version> of this repo; the app reads the latest release and replaces itself with its zip.

public let releasesRepo = "p-diego/serif"
public let latestReleasePage = URL(string: "https://github.com/\(releasesRepo)/releases/latest")!
public let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(releasesRepo)/releases/latest")!

public struct Release: Equatable, Sendable {
    public let version: String    // without the "v"
    public let page: URL
    public let zip: URL           // Serif-<version>.zip

    public init(version: String, page: URL, zip: URL) {
        self.version = version; self.page = page; self.zip = zip
    }
}

/// Numeric, part by part: 0.10 is newer than 0.9, 0.12.1 than 0.12. A tag's "v" doesn't count.
public func isNewer(_ remote: String, than local: String) -> Bool {
    remote.trimmingPrefix("v").compare(local.trimmingPrefix("v"), options: .numeric) == .orderedDescending
}

/// GitHub's releases/latest JSON: version without "v", page and the Serif-<version>.zip asset. Nil when one is missing,
/// the JSON is broken, or it is an error body ({"message": "Not Found"} while the repo has no release or is private).
public func parseRelease(_ data: Data) -> Release? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let tag = json["tag_name"] as? String,
          let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
          let assets = json["assets"] as? [[String: Any]] else { return nil }
    let version = String(tag.trimmingPrefix("v"))
    guard let asset = assets.first(where: { $0["name"] as? String == "Serif-\(version).zip" }),
          let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
    return Release(version: version, page: page, zip: zip)
}

/// At once if never tried; 24 h after a check that worked; 1 h after one that failed (no network at login, or GitHub's
/// limit of 60 unauthenticated requests an hour).
public func isDue(last: Date?, succeeded: Bool, now: Date) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= (succeeded ? 24 * 3600 : 3600)
}

/// The restart after the bundle is replaced, as `make install`: wait for this app to exit (with it alive, `open` would
/// just activate it), stop the old engine still running the old binary (SIGTERM: it exits 0, so launchd's KeepAlive
/// leaves it down), restart the agent on the new one (fails harmlessly when it isn't loaded: the app then starts the
/// engine itself), open the new copy. The bots resume their conversations on the new engine.
/// The app path is $0, so spaces can't break the script; pgrep and pkill never match this sh, their ancestor.
public func relaunchArguments(pid: Int32, uid: UInt32, app: String) -> [String] {
    ["-c", """
     while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
     pkill -f "$0/Contents/MacOS/serifd"; while pgrep -f "$0/Contents/MacOS/serifd" >/dev/null; do sleep 0.1; done
     launchctl kickstart -k gui/\(uid)/com.serif.engine 2>/dev/null
     open "$0"
     """, app]
}

extension ClientState {
    /// Bots mid-turn (working, or waiting on a request): restarting the engine for an update stops their reply.
    public var workingCount: Int {
        bots.values.filter { $0.bot.archivedAt == nil && $0.state.inTurn }.count
    }
}
