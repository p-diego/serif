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
    @State private var folderError: String?

    var body: some View {
        if !chosen.isEmpty {
            FlowLayout {
                ForEach(chosen, id: \.self) { pill($0) }
            }
        }
        Menu(kind == .skills ? String(localized: "Add skill") : String(localized: "Add plugin")) {
            ForEach(items.filter { !chosen.contains($0.id) }) { item in
                Button { chosen.append(item.id) } label: {
                    Text(item.name)
                    if !item.description.isEmpty {
                        Text(item.description.count > 80 ? String(item.description.prefix(79)) + "…" : item.description)
                    }
                }
            }
            if kind == .skills {
                if !items.isEmpty { Divider() }
                Button(String(localized: "From a folder…"), action: chooseFolder)
            }
        }
        .fixedSize()
        .disabled(kind == .plugins && items.allSatisfy { chosen.contains($0.id) })
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

    private func label(_ id: String) -> String {
        items.first { $0.id == id }?.name ?? (kind == .skills ? URL(fileURLWithPath: id).lastPathComponent : id)
    }

    /// A skill is its folder: gone without its SKILL.md. A plugin is gone when Claude Code no longer lists it.
    private func missing(_ id: String) -> Bool {
        kind == .skills ? !FileManager.default.fileExists(atPath: (id as NSString).appendingPathComponent("SKILL.md"))
                        : !items.contains { $0.id == id }
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

/// Pills left to right, wrapping onto new rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, point) in zip(subviews, arrange(width: bounds.width, subviews).points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}
