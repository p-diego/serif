import SwiftUI
import AppKit
import SerifCore

/// Skills or plugins chosen for a bot or a project (spec §6.4): pills with ✕, an Add menu with the user's own (and, for
/// skills, any folder with a SKILL.md), and the grey line of what the project already gives. One no longer on this Mac is
/// struck through: the engine leaves it out.
struct CatalogPicker: View {
    enum Kind { case skills, plugins }
    let kind: Kind
    let items: [CatalogItem]
    @Binding var chosen: [String]
    var inherited: [String] = []
    /// False while the plugin list has not been read (Codex's comes from the engine): a list not read yet marks nothing missing.
    var known = true
    @State private var folderError: String?

    var body: some View {
        if !chosen.isEmpty {
            ChipFlow {
                ForEach(chosen, id: \.self) { pill($0) }
            }
        }
        Menu(kind == .skills ? String(localized: "Add skill") : String(localized: "Add plugin")) {
            ForEach(offered) { item in
                Button { chosen.append(item.id) } label: {
                    Text(item.name)
                    let subtitle = subtitle(item)
                    if !subtitle.isEmpty { Text(subtitle.count > 80 ? String(subtitle.prefix(79)) + "…" : subtitle) }
                }
            }
            if kind == .skills {
                if !offered.isEmpty { Divider() }
                Button(String(localized: "From a folder…"), action: chooseFolder)
            }
        }
        .fixedSize()
        .disabled(kind == .plugins && offered.isEmpty)
        if let folderError { Text(folderError).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.red) }
        if !inherited.isEmpty {
            Text(String(localized: "From the project: \(inherited.map(label).joined(separator: ", "))"))
                .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func pill(_ id: String) -> some View {
        let gone = missing(id)
        return HStack(spacing: 5) {
            Text(label(id)).strikethrough(gone).foregroundStyle(gone ? Theme.textTertiary : Theme.text)
            Button { chosen.removeAll { $0 == id } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: Theme.Size.small)).lineLimit(1)
        .padding(.vertical, 4).padding(.horizontal, 10)
        .background(Capsule().fill(Theme.active))
        .help(gone ? String(localized: "Not found on this Mac") : id)
    }

    /// What Add offers: neither chosen here nor already given by the project.
    private var offered: [CatalogItem] { items.filter { !chosen.contains($0.id) && !inherited.contains($0.id) } }

    /// A plugin's menu line starts with where it comes from: two plugins can share a name (installed and synced).
    private func subtitle(_ item: CatalogItem) -> String {
        kind == .plugins ? [source(item.id), item.description].filter { !$0.isEmpty }.joined(separator: " · ") : item.description
    }

    /// "claude.ai" for a plugin synced from there, else its marketplace ("figma@claude-plugins-official").
    private func source(_ id: String) -> String {
        id.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) ?? "claude.ai"
    }

    private func label(_ id: String) -> String {
        guard let item = items.first(where: { $0.id == id }) else {
            return kind == .skills ? URL(fileURLWithPath: id).lastPathComponent : id
        }
        let twin = kind == .plugins && items.contains { $0.name == item.name && $0.id != id }
        return twin ? "\(item.name) (\(source(id)))" : item.name
    }

    /// A skill is its folder: gone without its SKILL.md. A plugin is gone when its agent's list, once read, no longer has it.
    private func missing(_ id: String) -> Bool {
        kind == .skills ? !FileManager.default.fileExists(atPath: (id as NSString).appendingPathComponent("SKILL.md"))
                        : known && !items.contains { $0.id == id }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder that contains SKILL.md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
            folderError = String(localized: "This folder has no SKILL.md")
            return
        }
        folderError = nil
        if !chosen.contains(url.path) { chosen.append(url.path) }
    }
}
