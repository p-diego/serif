import SwiftUI
import SerifCore

/// Mascots scattered on an ellipse around the centre, like the store screenshot of the reference app: the empty state and
/// the first launch.
struct ScatteredMascots: View {
    private let faces = emptyStateFaces(count: 8)
    private let sizes: [CGFloat] = [64, 48, 56, 70, 52, 66, 58, 72]

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                // An ellipse around the centre, starting off-axis so nothing sits right above the title.
                let angle = (Double(i) / 8 + 0.06) * 2 * .pi
                MascotImage(face: faces[i], mood: .watch, size: sizes[i])
                    .rotationEffect(.degrees(Double((i * 37) % 21) - 10))
                    .offset(x: cos(angle) * 270, y: sin(angle) * 190)
            }
        }
    }
}

/// No projects yet (and the first launch already done): mascots around the title.
struct NoProjectsView: View {
    let client: EngineClient

    var body: some View {
        ZStack {
            ScatteredMascots()
            VStack(spacing: 8) {
                Text("Serif").font(.system(size: 28, weight: .semibold))
                Text(String(localized: "Your bots, always at work")).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
                Button { client.showNewProject() } label: {
                    Text(String(localized: "Create your first project")).font(.system(size: Theme.Size.body, weight: .medium))
                        .foregroundStyle(Theme.userBubbleText).padding(.horizontal, 20).frame(height: 38)
                        .background(Capsule().fill(Theme.userBubble))
                }.buttonStyle(.plain).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the engine has not answered for a while.
struct EngineOffOverlay: View {
    let client: EngineClient

    var body: some View {
        VStack(spacing: 10) {
            Text(String(localized: "The engine is not running")).font(.system(size: Theme.Size.title, weight: .semibold))
            Text(String(localized: "Your bots work in the engine, which keeps running when the app is closed."))
                .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button { client.startEngine() } label: {
                Text(String(localized: "Start")).font(.system(size: Theme.Size.body, weight: .medium))
                    .foregroundStyle(Theme.userBubbleText).padding(.horizontal, 22).frame(height: 36)
                    .background(Capsule().fill(Theme.userBubble))
            }.buttonStyle(.plain).padding(.top, 6)
        }
        .padding(28).frame(width: 380)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pane.opacity(0.6))
    }
}
