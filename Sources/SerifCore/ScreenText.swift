import Foundation

/// `trustPrompt`: the trust dialog with "No, exit" selected; `trustConfirm`: the same dialog with "Yes" selected.
public enum ScreenSignal: Hashable, Sendable { case trustPrompt, trustConfirm, interrupted, planApproval }

/// Recognises Claude Code's interactive screens. Whitespace and control characters are ignored on both sides: captured
/// screens often have their spaces squashed, and a headless terminal reads the cells the TUI skipped as NUL.
public func screenSignals(in screen: String) -> Set<ScreenSignal> {
    func squash(_ s: String) -> String {
        String(s.unicodeScalars.filter { !$0.properties.isWhitespace && $0.properties.generalCategory != .control })
    }
    let text = squash(screen)
    var found: Set<ScreenSignal> = []
    if text.contains(squash("Is this a project you created or one you trust")) {
        if text.contains(squash("❯ No, exit")) { found.insert(.trustPrompt) }
        if text.contains(squash("❯ Yes, I trust this folder")) { found.insert(.trustConfirm) }
    }
    if text.contains(squash("Interrupted · What should Claude do instead?")) { found.insert(.interrupted) }
    if text.contains(squash("Would you like to proceed?")) && text.contains(squash("Ready to code?")) { found.insert(.planApproval) }
    return found
}
