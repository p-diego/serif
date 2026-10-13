import SwiftUI
import AppKit

/// The message field: "+" (disabled in 0.1), growing text up to 6 lines, stop while working, send.
struct Composer: View {
    let botName: String
    let working: Bool
    let onSend: (String) async -> Bool    // false: the send failed, the text comes back
    let onStop: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(Theme.textQuaternary)
                .frame(width: 34, height: 34).background(Circle().fill(Theme.fillSecondary))
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
            .buttonStyle(.plain).disabled(empty).opacity(empty ? 0.4 : 1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.composer).fill(Theme.composerFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.composer).stroke(Theme.composerBorder, lineWidth: 1))
        .onAppear { focused = true }
    }

    private func send() {
        guard !empty else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        Task { if !(await onSend(t)), text.isEmpty { text = t } }
    }
}
