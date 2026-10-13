import SwiftUI
import SerifCore

/// Big live preview, "random", the nine shapes and the two colour rows.
struct FacePicker: View {
    @Binding var face: BotFace
    let existing: [BotFace]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                LiveMascot(face: face, mood: .watch, avatar: 96)
                    .frame(width: 96 + 2 * LiveMascot.inset, height: 96 + 2 * LiveMascot.inset)
                Button(String(localized: "Random")) { face = randomFace(existing: existing) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(MascotKind.allCases, id: \.self) { kind in
                        let candidate = BotFace(shape: kind, body: face.body, eyes: face.eyes)
                        MascotImage(face: candidate, mood: .watch, size: 30).padding(4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(face.shape == kind ? Theme.active : .clear))
                            .contentShape(Rectangle()).onTapGesture { face.shape = kind }
                    }
                }
                swatches(String(localized: "Body"), selection: $face.body)
                swatches(String(localized: "Eyes"), selection: $face.eyes)
            }
        }
    }

    private func swatches(_ label: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: Theme.Size.caption)).foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .leading)
            ForEach(mascotSwatches, id: \.self) { value in
                Circle().fill(Color(nsColor: NSColor(cgColor: cgColor(hex: value)) ?? .gray)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
                    .overlay(Circle().stroke(Theme.text, lineWidth: selection.wrappedValue == value ? 2 : 0).padding(-3))
                    .contentShape(Circle()).onTapGesture { selection.wrappedValue = value }
            }
        }
    }
}
