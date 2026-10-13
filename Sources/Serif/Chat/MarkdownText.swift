import SwiftUI

/// Markdown for bot text: inline styling per chunk (newlines kept), fenced code blocks monospaced in a scrollable box.
struct MarkdownText: View {
    let text: String
    var color: Color = Theme.text

    private enum Block: Identifiable {
        case prose(Int, AttributedString), code(Int, String)
        var id: Int { switch self { case .prose(let i, _), .code(let i, _): i } }
    }

    /// Splits on ``` fences; an unclosed fence (still streaming) counts as code to the end.
    private var blocks: [Block] {
        var out: [Block] = []
        var prose: [String] = [], code: [String] = []
        var inCode = false
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.prose(out.count, Self.inline(joined))) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(out.count, code.joined(separator: "\n"))); code = [] } else { flushProse() }
                inCode.toggle()
            } else if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { out.append(.code(out.count, code.joined(separator: "\n"))) } else { flushProse() }
        return out
    }

    /// Bullets and headings are rewritten line by line (inline-only parsing knows neither).
    private static func inline(_ text: String) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            let trimmed = l.drop(while: { $0 == " " })
            let indent = String(l.prefix(l.count - trimmed.count))
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { l = indent + "• " + trimmed.dropFirst(2) }
            else if trimmed.hasPrefix("#") {
                let body = trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " })
                if !body.isEmpty { l = "**\(body)**" }
            }
            return l
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .prose(_, let a): Text(a).font(.system(size: Theme.Size.body)).foregroundStyle(color)
                case .code(_, let c):
                    ScrollView(.horizontal) {
                        Text(c).font(.system(size: 13, design: .monospaced)).foregroundStyle(color).padding(10)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .scrollIndicators(.automatic)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.codeBackground))
                }
            }
        }
    }
}
