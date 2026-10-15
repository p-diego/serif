import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SerifCore

/// The message field: "+" to attach files, growing text up to 6 lines, the files chosen as chips above (pasted with
/// ⌘V or dropped, spec §4 of 0.7), stop while working, send. A message may be files alone.
struct Composer: View {
    let botName: String
    let working: Bool
    let onSend: (String, [AttachedFile]) async -> Bool    // false: the send failed, text and files come back
    let onStop: () -> Void
    @State private var text = ""
    @State private var files: [AttachedFile] = []
    @State private var pasteMonitor: Any?
    @State private var composerWindow: NSWindow?          // the window the field had focus in: ⌘V is ours only there
    @State private var tooBig: String?                    // a file over 16 MB, not read (spec §4)
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }
    /// Over the limits (spec §4, §10): said under the chips, and nothing goes until it is fixed.
    private var problem: String? { attachmentProblem(files.map { ($0.name, $0.data.count) }).map(attachmentProblemText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !files.isEmpty {
                ChipFlow {
                    ForEach(Array(files.enumerated()), id: \.offset) { i, file in
                        AttachmentChip(file: file) { files.remove(at: i) }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 8)
                if let problem { Text(problem).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.red).padding(.horizontal, 10) }
            }
            if let tooBig {
                Text(String(localized: "A file is larger than 16 MB: \(tooBig)")).font(.system(size: Theme.Size.label))
                    .foregroundStyle(Theme.red).padding(.horizontal, 10).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseFiles) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34).background(Circle().fill(Theme.fillSecondary))
                }
                .buttonStyle(.plain).help(String(localized: "Attach files…"))
                TextField(String(localized: "Message \(botName)"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...6)
                    .focused($focused).padding(.vertical, 7)
                    .onKeyPress(.return, phases: .down) { press in
                        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                        if editor?.hasMarkedText() == true { return .ignored }    // Return confirms the IME composition
                        if press.modifiers.contains(.shift) {
                            if let editor { editor.insertNewlineIgnoringFieldEditor(nil) } else { text += "\n" }
                            return .handled
                        }
                        send(); return .handled
                    }
                if working {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 12)).foregroundStyle(Theme.text)
                            .frame(width: 34, height: 34).background(Circle().fill(Theme.fillSecondaryHover))
                    }
                    .buttonStyle(.plain).help(String(localized: "Stop"))
                }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.userBubbleText)
                        .frame(width: 34, height: 34).background(Circle().fill(Theme.userBubble))
                }
                .buttonStyle(.plain).disabled(empty || problem != nil).opacity(empty || problem != nil ? 0.4 : 1)
            }
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.composer).fill(Theme.composerFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.composer).stroke(Theme.composerBorder, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        }
        .onChange(of: focused) { if focused { composerWindow = NSApp.keyWindow } }
        .onAppear { focused = true; watchPaste() }
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
    }

    /// ⌘V with files or a picture on the pasteboard attaches them (spec §4). The menu's Paste reaches the field editor
    /// before any view, so the key is seen here first; text is left to the field.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused, let window = event.window, window === composerWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pasted = pastedFiles()
            guard !pasted.urls.isEmpty || pasted.image != nil else { return event }
            if let image = pasted.image { files.append(image) }
            add(pasted.urls)
            return nil
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Attach")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// The chips for `urls`, read off the main thread; a file over the limit is named instead (spec §4).
    private func add(_ urls: [URL]) {
        tooBig = nil
        guard !urls.isEmpty else { return }
        Task {
            let loaded = await loadFiles(urls)
            files += loaded.files
            tooBig = loaded.tooBig.first
        }
    }

    private func send() {
        guard !empty, problem == nil else { return }
        let (t, chosen) = (text.trimmingCharacters(in: .whitespacesAndNewlines), files)
        text = ""; files = []
        Task {
            if !(await onSend(t, chosen)) {
                if text.isEmpty { text = t }
                if files.isEmpty { files = chosen }
            }
        }
    }
}

/// The limits in the app's language (spec §10).
func attachmentProblemText(_ problem: String) -> String {
    problem.hasPrefix("at most") ? String(localized: "At most \(AttachmentRules.maxFiles) files per message")
        : String(localized: "A file is larger than 16 MB: \(problem.components(separatedBy: " is larger").first ?? "")")
}

/// Chips left to right, wrapping onto new rows (the catalog picker's layout, for the composer).
struct ChipFlow: Layout {
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
