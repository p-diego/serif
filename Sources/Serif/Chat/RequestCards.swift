import SwiftUI
import SerifCore

/// Permission, question and plan cards (UI-APP §5). The same prompt is open in the bot's terminal: the first answer wins.
struct RequestCard: View {
    let request: PendingRequest
    let resolution: RequestResolution?
    let given: RequestAnswer?                       // what was answered in the app, stored with the transcript
    let client: EngineClient

    @State private var busy = false
    @State private var error: String?
    @State private var denyFieldOpen = false
    @State private var chosen: [Int: [String]] = [:]    // question index -> labels in the order picked

    private var questions: [QuestionSpec] { questionSpecs(request) }
    /// Needs the Send button: several questions, or any multiple-choice one.
    private var needsSend: Bool { questions.count > 1 || questions.contains { $0.multiSelect } }

    private func pick(_ qi: Int, _ label: String) {
        guard !busy, questions.indices.contains(qi) else { return }
        if questions[qi].multiSelect {
            var list = chosen[qi] ?? []
            if let i = list.firstIndex(of: label) { list.remove(at: i) } else { list.append(label) }
            chosen[qi] = list
        } else {
            chosen[qi] = [label]
            if !needsSend { sendAnswers() }    // a single plain question answers on click
        }
    }
    private func sendAnswers() { submit(questionAnswer(questions, chosen: chosen)) }

    /// Typing A, B, C picks that option of the first question still open (no modifiers: Cmd+A and friends pass through).
    private func letterKey(_ press: KeyPress) -> KeyPress.Result {
        let qs = questions
        guard request.kind == .question, !busy, press.modifiers.isEmpty,
              let idx = qs.indices.first(where: { (chosen[$0] ?? []).isEmpty }) ?? qs.indices.first(where: { qs[$0].multiSelect }),
              let n = press.characters.uppercased().unicodeScalars.first,
              n.value >= 65, Int(n.value - 65) < qs[idx].options.count else { return .ignored }
        pick(idx, qs[idx].options[Int(n.value - 65)].label)
        return .handled
    }
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let resolution { resolvedLine(resolution) } else { open }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sends the answer; on an engine error the card stays open with the message under the buttons.
    private func submit(_ answer: RequestAnswer) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            do { try await client.answer(request: request.id, answer) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    // MARK: open

    @ViewBuilder private var open: some View {
        Group {
            switch request.kind {
            case .permission: PermissionBody(request: request, busy: busy, error: error, submit: submit, fieldOpen: $denyFieldOpen)
            case .question: QuestionBody(questions: questions, chosen: chosen, needsSend: needsSend, busy: busy, error: error, pick: pick, send: sendAnswers)
            case .plan: PlanBody(request: request, busy: busy, error: error, submit: submit)
            }
        }
        .padding(12).frame(maxWidth: request.kind == .question ? 560 : 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.botBubble))
        .focusable().focused($focused).focusEffectDisabled()
        .onTapGesture { focused = true }
        // Take the keyboard (Esc, A/B/C) unless the user is typing somewhere, e.g. in the composer.
        .onAppear { if !(NSApp.keyWindow?.firstResponder is NSText) { focused = true } }
        .onKeyPress(characters: .letters, phases: .down, action: letterKey)
        .onKeyPress(.escape) {
            guard request.kind == .permission, !busy, !denyFieldOpen else { return .ignored }
            submit(.deny(message: nil)); return .handled
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: resolved

    private func resolvedLine(_ resolution: RequestResolution) -> some View {
        let (text, kind) = resolvedLabel(resolution)
        return HStack(spacing: 8) {
            Text(cardTitle(request)).font(.system(size: Theme.Size.body, weight: .medium))
            StatusPill(kind: kind, text: text)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(Capsule().fill(Theme.botBubble))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolvedLabel(_ resolution: RequestResolution) -> (String, StatusPill.Kind) {
        switch resolution {
        case .answeredInTerminal: return (String(localized: "Resolved in the terminal"), .neutral)
        case .cancelled: return (String(localized: "Cancelled"), .neutral)
        case .answeredInApp: break
        }
        switch given {
        case .allow?: return (String(localized: "Allowed"), .done)
        case .allowSession?: return (String(localized: "Allowed for this session"), .done)
        case .deny?, .rejectPlan?: return (request.kind == .plan ? String(localized: "Rejected") : String(localized: "Denied"), .failed)
        case .approvePlan?: return (String(localized: "Approved"), .done)
        case .denyAndStop?: return (String(localized: "Denied and stopped"), .failed)
        case .answers(let a)?:
            return (String(localized: "Answered: \(a.values.flatMap { $0 }.joined(separator: ", "))"), .done)
        case nil: return (String(localized: "Answered"), .done)    // answered before this session of the app
        }
    }
}

private func cardTitle(_ r: PendingRequest) -> String {
    switch r.kind {
    case .plan: return String(localized: "Plan")
    case .question: return String(localized: "Question")
    case .permission:
        switch r.toolName {
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return String(localized: "Edit file")
        default: return r.toolName.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? r.toolName
        }
    }
}

// MARK: - Pieces

/// The capsule button of the cards in the chat (requests, Claude Code help) and of the first launch.
struct CardButton: View {
    enum Style { case primary, tinted, ghost }
    let title: String
    var style: Style = .tinted
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: Theme.Size.body)).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 32)
                .foregroundStyle(style == .primary ? Theme.pane : Theme.text)
                .background(Capsule().fill(style == .primary ? Theme.text : style == .tinted ? Theme.fillSecondary : .clear))
                .overlay(Capsule().stroke(style == .tinted ? Theme.borderTertiary : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
    }
}

private struct CardHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: Theme.Size.body, weight: .medium))
            Spacer(minLength: 8)
            StatusPill(kind: .waiting, text: String(localized: "Pending"))
        }
    }
}

private struct ErrorLine: View {
    let text: String?
    var body: some View {
        if let text { Text(text).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.red) }
    }
}

/// Optional/required message field with a send button, used by "Nega" and "Rifiuta e spiega".
private struct MessageField: View {
    let placeholder: String
    let required: Bool
    let busy: Bool
    let close: () -> Void    // Esc closes the field and sends nothing
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focus: Bool
    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: Theme.Size.body))
                .focused($focus).onSubmit(go)
                .onKeyPress(.escape) { close(); return .handled }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(Theme.composerFill))
                .overlay(Capsule().stroke(Theme.composerBorder, lineWidth: 1))
            CardButton(title: String(localized: "Send"), style: .primary,
                       enabled: !busy && (!required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), action: go)
        }
        .onAppear { focus = true }
    }
    private func go() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && t.isEmpty { return }
        send(t)
    }
}

/// Monospaced box, six lines until expanded.
private struct CodeBox: View {
    let text: String
    @State private var expanded = false
    private let limit = 6
    private var long: Bool { text.split(separator: "\n", omittingEmptySubsequences: false).count > limit || text.count > 400 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(size: Theme.Size.small, design: .monospaced)).textSelection(.enabled)
                .lineLimit(expanded ? nil : limit).frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(expanded ? String(localized: "Show less") : String(localized: "Show all")) { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 8).padding(.leading, 12).padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.codeBackground))
    }
}

// MARK: - Permission

private struct PermissionBody: View {
    let request: PendingRequest, busy: Bool, error: String?
    let submit: (RequestAnswer) -> Void
    @Binding var fieldOpen: Bool    // the card's Esc = deny must not fire while the message field is open

    private var path: String? { request.input["file_path"]?.string }
    private var detail: String {
        let i = request.input
        if let c = i["command"]?.string { return c }
        if let c = i["content"]?.string { return c }
        if let old = i["old_string"]?.string, let new = i["new_string"]?.string {
            return old.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }.joined(separator: "\n") + "\n"
                + new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }.joined(separator: "\n")
        }
        return i.compactText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: cardTitle(request))
            if let path { Text(path).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.head) }
            if let d = request.input["description"]?.string {
                Text(d).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
            }
            CodeBox(text: detail)
            // Buttons wrap with gap 8; "Nega" sits on the right when everything fits on one line.
            HStack(spacing: 8) {
                CardButton(title: String(localized: "Allow"), style: .primary, enabled: !busy) { submit(.allow) }
                CardButton(title: String(localized: "Allow for this session"), enabled: !busy) { submit(.allowSession) }
                Spacer(minLength: 0)
                CardButton(title: String(localized: "Deny"), style: .ghost, enabled: !busy) { fieldOpen.toggle() }
            }
            if fieldOpen {
                MessageField(placeholder: String(localized: "Tell the bot why (optional)"), required: false, busy: busy, close: { fieldOpen = false }) {
                    submit(.deny(message: $0.isEmpty ? nil : $0))
                }
            }
            ErrorLine(text: error)
        }
    }
}

// MARK: - Question

private struct QuestionBody: View {
    let questions: [QuestionSpec]
    let chosen: [Int: [String]]
    let needsSend: Bool, busy: Bool, error: String?
    let pick: (Int, String) -> Void
    let send: () -> Void

    private var answered: Bool { !questions.isEmpty && questions.indices.allSatisfy { !(chosen[$0] ?? []).isEmpty } }

    var body: some View {
        let qs = questions
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(qs.enumerated()), id: \.offset) { qi, q in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let h = q.header {
                            Text(h).font(.system(size: Theme.Size.label, weight: .medium)).foregroundStyle(Theme.textSecondary)
                                .padding(.vertical, 2).padding(.horizontal, 8).background(Capsule().fill(Theme.fillSecondary))
                        }
                        Spacer(minLength: 8)
                        if qi == 0 { StatusPill(kind: .waiting, text: String(localized: "Pending")) }
                    }
                    Text(q.text).font(.system(size: Theme.Size.body, weight: .medium))
                    if q.multiSelect { Text("Choose all that apply").font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary) }
                    optionList(qi, q)
                }
            }
            if needsSend {
                HStack { Spacer(); CardButton(title: String(localized: "Send"), style: .primary, enabled: answered && !busy, action: send) }
            }
            ErrorLine(text: error)
        }
    }

    private func optionList(_ qi: Int, _ q: QuestionSpec) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { oi, o in
                if oi > 0 { Divider().overlay(Theme.borderTertiary) }
                let on = chosen[qi]?.contains(o.label) ?? false
                Button { pick(qi, o.label) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(UnicodeScalar(UInt8(65 + min(oi, 25)))))
                            .font(.system(size: Theme.Size.caption, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 18).padding(.vertical, 1).padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label).font(.system(size: Theme.Size.body))
                            if let d = o.description, !d.isEmpty {
                                Text(d).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 4)
                        if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? Theme.active : .clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(busy)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.borderTertiary, lineWidth: 0.5))
    }
}

// MARK: - Plan

private struct PlanBody: View {
    let request: PendingRequest, busy: Bool, error: String?
    let submit: (RequestAnswer) -> Void
    @State private var rejecting = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: cardTitle(request))
            ScrollView {
                MarkdownText(text: request.input["plan"]?.string ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 20), 300))
            HStack(spacing: 8) {
                CardButton(title: String(localized: "Approve"), style: .primary, enabled: !busy) { submit(.approvePlan) }
                CardButton(title: String(localized: "Reject and explain"), enabled: !busy) { rejecting.toggle() }
            }
            if rejecting {
                MessageField(placeholder: String(localized: "What should change?"), required: true, busy: busy, close: { rejecting = false }) {
                    submit(.rejectPlan(message: $0))
                }
            }
            ErrorLine(text: error)
        }
    }
}
