import AppKit
import Security
import SerifCore

enum UpdateError: LocalizedError {
    case notInstalled, http(Int), noRelease, notWritable(String), unpack, notNewerSerif, signature
    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "Only the copy in Applications updates itself")
        case .http(let code): String(localized: "GitHub answered \(code)")
        case .noRelease: String(localized: "No release with Serif's zip")
        case .notWritable(let folder): String(localized: "Can't write to \(folder)")
        case .unpack: String(localized: "Can't unpack the download")
        case .notNewerSerif: String(localized: "The download isn't a newer Serif")
        case .signature: String(localized: "The download isn't signed like this copy")
        }
    }
}

/// Unpacks the zip with ditto (as `make dist` packs it) in a temporary folder, then checks it: bundle id com.serif.app,
/// a version newer than `current`, and a signature that satisfies the running copy's designated requirement (same Apple
/// Development certificate: an ad-hoc or foreign build fails). Blocking: off the main actor.
func unpackAndVerify(_ zip: Data, newerThan current: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serif-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var verified = false
    defer { if !verified { try? FileManager.default.removeItem(at: dir) } }    // a rejected download doesn't stay on disk
    let file = dir.appendingPathComponent("Serif.zip")
    try zip.write(to: file)
    guard EngineClient.run("/usr/bin/ditto", ["-x", "-k", file.path, dir.path]) else { throw UpdateError.unpack }
    let app = dir.appendingPathComponent("Serif.app")
    guard let info = Bundle(url: app)?.infoDictionary,    // a new folder every time: no stale Bundle cache
          info["CFBundleIdentifier"] as? String == "com.serif.app",
          let version = info["CFBundleShortVersionString"] as? String, isNewer(version, than: current)
    else { throw UpdateError.notNewerSerif }
    var me: SecCode?, meStatic: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
          SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
          SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
          SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new,
          SecStaticCodeCheckValidity(new, [], requirement) == errSecSuccess
    else { throw UpdateError.signature }
    verified = true
    return app
}

/// Checks GitHub at launch and then daily, and installs a newer release: the sidebar row and the app menu read `state`.
/// `failed` only comes from an install; a failed check leaves the state as it was.
@MainActor @Observable
final class Updater {
    enum State: Equatable { case idle, upToDate, available(Release), downloading(Release), failed(String) }
    private(set) var state = State.idle
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    var isUpdating: Bool { if case .downloading = state { true } else { false } }

    private let client: EngineClient
    @ObservationIgnored private var last: Date?
    @ObservationIgnored private var succeeded = false

    init(client: EngineClient) { self.client = client }

    /// Only the installed copy updates itself; a development build never does. The Applications prefix also rules out
    /// a copy run from the disk image (/Volumes) or translocated by Gatekeeper.
    private var isInstalledCopy: Bool { EngineClient.runsFromApplications }

    /// At launch; the network only when a check is due (`isDue`), so a 10-minute tick is enough.
    func startChecking() {
        Task {
            while true {
                if isInstalledCopy, isDue(last: last, succeeded: succeeded, now: Date()) { try? await check() }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Reads the latest release; throws what went wrong, for the menu's alert.
    func check() async throws {
        guard isInstalledCopy else { throw UpdateError.notInstalled }
        last = Date()
        do {
            var request = URLRequest(url: latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.http(code) }
            guard let release = parseRelease(data) else { throw UpdateError.noRelease }
            succeeded = true
            if isUpdating { return }    // a download in progress is left alone
            state = isNewer(release.version, than: current) ? .available(release) : .upToDate
        } catch {
            succeeded = false
            NSLog("Serif: update check failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// "Check for Updates…": checks now and answers with an alert.
    func checkFromMenu() async {
        guard !isUpdating else { return }
        let alert = NSAlert()
        do { try await check() } catch {
            alert.messageText = String(localized: "Couldn't check for updates")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        guard case .available(let release) = state else {
            alert.messageText = String(localized: "Serif \(current) is the latest version")
            alert.runModal()
            return
        }
        alert.messageText = String(localized: "Serif \(release.version) is available")
        alert.addButton(withTitle: String(localized: "Update"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { await update() }
    }

    /// "Update": restarting the engine stops the reply of the bots mid-turn, so with any of them it asks first.
    func update() async {
        let working = client.state.workingCount
        if working > 0 {
            let alert = NSAlert()
            alert.messageText = working == 1 ? String(localized: "1 bot is working — its reply will stop")
                : String(localized: "\(working) bots are working — their reply will stop")
            alert.addButton(withTitle: String(localized: "Update now"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        await install()
    }

    /// Download, unpack, verify, replace, restart. Replacing is the last step: any error before it leaves the installed
    /// copy as it was.
    private func install() async {
        guard case .available(let release) = state else { return }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else { return fail(UpdateError.notWritable(folder)) }
        state = .downloading(release)
        do {
            let (data, response) = try await URLSession.shared.data(from: release.zip)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.http(code) }
            let version = current
            let new = try await Task.detached { try unpackAndVerify(data, newerThan: version) }.value
            defer { try? FileManager.default.removeItem(at: new.deletingLastPathComponent()) }    // the zip and the temporary folder
            _ = try FileManager.default.replaceItemAt(app, withItemAt: new)
        } catch {
            return fail(error)
        }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = relaunchArguments(pid: getpid(), uid: getuid(), app: app.path)
        do { try sh.run() } catch { return fail(error) }    // not waited for: it outlives us
        NSApp.terminate(nil)
    }

    /// Also counts as a failed check: the next one is due in an hour, which brings back "Update to …" once the network
    /// is back instead of leaving "Update failed" until the next day.
    private func fail(_ error: Error) {
        NSLog("Serif: update failed: \(error.localizedDescription)")
        last = Date()
        succeeded = false
        state = .failed(error.localizedDescription)
    }
}
