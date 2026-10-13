import Foundation

/// Links the chosen skills into `<folder>/.claude/skills/<skill folder name>`, where Claude Code finds them (spec §6.2),
/// and drops the links of skills no longer chosen. Serif owns only the symbolic links there: anything else (a skill the bot
/// wrote itself) is never touched. Returns one line per skill left out, for the engine log; the bot starts without it.
func linkSkills(_ skills: [String], into folder: URL) -> [String] {
    let fm = FileManager.default
    let dir = folder.appendingPathComponent(".claude/skills")
    // A linked `.claude` or `skills` leads outside Serif (the user's own skills): never followed, nothing is linked.
    for path in [folder.appendingPathComponent(".claude").path, dir.path] where (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
        return ["skills left out: \(path) is a link"]
    }
    var problems: [String] = []
    var wanted: [String: String] = [:]          // link name → skill folder
    for skill in skills {
        let name = (skill as NSString).lastPathComponent
        if wanted[name] != nil { problems.append("skill \(skill) left out: another chosen skill is named \(name)"); continue }
        guard fm.fileExists(atPath: (skill as NSString).appendingPathComponent("SKILL.md")) else {
            problems.append("skill \(skill) left out: no SKILL.md there")
            continue
        }
        wanted[name] = skill
    }
    // Links to a skill no longer chosen, or to another folder, go first.
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
        let path = dir.appendingPathComponent(name).path
        guard let target = try? fm.destinationOfSymbolicLink(atPath: path), target != wanted[name] else { continue }
        do { try fm.removeItem(atPath: path) } catch { problems.append("cannot remove the link \(path): \(error.localizedDescription)") }
    }
    guard !wanted.isEmpty else { return problems }
    do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
        return problems + ["cannot create \(dir.path): \(error.localizedDescription)"]
    }
    for (name, skill) in wanted.sorted(by: { $0.key < $1.key }) {
        let path = dir.appendingPathComponent(name).path
        if (try? fm.destinationOfSymbolicLink(atPath: path)) == skill { continue }
        // Whatever is still there is the bot's own: other links were removed above.
        if (try? fm.attributesOfItem(atPath: path)) != nil { problems.append("skill \(skill) left out: \(path) is the bot's own"); continue }
        do { try fm.createSymbolicLink(atPath: path, withDestinationPath: skill) } catch {
            problems.append("skill \(skill) left out: \(error.localizedDescription)")
        }
    }
    return problems
}
