// Writes the app icon's Icon Composer document from the mascot code (make icon-layers): one group per mascot with its
// eyes, body and border as SVG layers on the full 1024 pt canvas, so actool gives each mascot its own glass.
// Built together with Sources/SerifCore/Mascot/*.swift (one module: the figure's paths are internal).
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])   // …/serif_icon.icon
let canvas = 1024.0

struct Mascot { let name: String; let kind: MascotKind; let body: Int; let cx, base, height: Double; let mirrored: Bool; let gaze: Double }
// Front to back (Icon Composer's first group is on top): white in front, the two at its sides look at it.
let team = [
    Mascot(name: "White", kind: .mostro, body: 0xF5F7FC, cx: 512, base: 800, height: 460, mirrored: false, gaze: 0),
    Mascot(name: "Blue", kind: .mirtillo, body: 0x739EFA, cx: 224, base: 750, height: 340, mirrored: false, gaze: 0.35),
    Mascot(name: "Orange", kind: .drop, body: 0xF08A24, cx: 800, base: 750, height: 340, mirrored: true, gaze: 0.35),
]
let eyeColor = 0x14141A

// The same placement as drawMascot inside an avatarLayout square whose bottom sits on `base`.
func placement(_ m: Mascot, _ g: MascotGeometry) -> (CGAffineTransform, scale: Double) {
    let l = avatarLayout(g, avatar: m.height), s = l.size.height / 100
    var t = CGAffineTransform(translationX: m.cx - m.height / 2 + l.offset.x, y: m.base - m.height + l.offset.y)
    if m.mirrored { t = t.translatedBy(x: l.size.width, y: 0).scaledBy(x: -1, y: 1) }
    return (t.translatedBy(x: (l.size.width - 100 * s) / 2, y: 0).scaledBy(x: s, y: s), s)
}

let figures = team.map { m -> (body: CGPath, eyes: [CGPath], scale: Double) in
    let g = MascotGeometry.of(m.kind)
    var look = MascotLook(); look.left = .open; look.right = .open; look.gazeX = m.gaze
    let fig = mascotFigure(g, look), (t, s) = placement(m, g)
    return (moved(fig.body, t), fig.eyes.map { moved($0, t) }, s)
}
// Centre the whole team on the canvas.
let box = figures.map(\.body.boundingBoxOfPath).reduce(CGRect.null) { $0.union($1) }
let centre = CGAffineTransform(translationX: canvas / 2 - box.midX, y: canvas / 2 - box.midY)

func svgPath(_ p: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    p.applyWithBlock { e in
        let pt = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(f(pt[0].x)) \(f(pt[0].y))"
        case .addLineToPoint: d += "L\(f(pt[0].x)) \(f(pt[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(pt[0].x)) \(f(pt[0].y)) \(f(pt[1].x)) \(f(pt[1].y))"
        case .addCurveToPoint: d += "C\(f(pt[0].x)) \(f(pt[0].y)) \(f(pt[1].x)) \(f(pt[1].y)) \(f(pt[2].x)) \(f(pt[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}
func svg(_ paths: [CGPath], fill: Int, opacity: Double = 1) -> String {
    let body = paths.map { "  <path fill=\"#\(String(format: "%06X", fill))\" fill-opacity=\"\(opacity)\" fill-rule=\"evenodd\" d=\"\(svgPath(moved($0, centre)))\"/>" }
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
        + body.joined(separator: "\n") + "\n</svg>\n"
}

let assets = out.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
var groups: [[String: Any]] = []
for (m, fig) in zip(team, figures) {
    // The border as in drawMascot: the body grown by the 2 / 0.27 line (half of it outside), grey at 60%.
    let line = 2 / 0.27 * fig.scale
    let border = fig.body.union(fig.body.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 10))
    let gray = Int((mascotBorderGray.components![0] * 255).rounded()) * 0x010101
    let layers: [(String, String)] = [("eyes", svg(fig.eyes, fill: eyeColor)), ("body", svg([fig.body], fill: m.body)),
                                      ("border", svg([border], fill: gray, opacity: 0.6))]
    for (part, text) in layers { try! text.write(to: assets.appendingPathComponent("\(m.name.lowercased())-\(part).svg"), atomically: true, encoding: .utf8) }
    groups.append(["name": m.name, "shadow": ["kind": "neutral", "opacity": 0.5],
                   "layers": layers.map { part, _ in ["name": "\(m.name) · \(part)", "image-name": "\(m.name.lowercased())-\(part).svg",
                                                      "position": ["scale": 1.0, "translation-in-points": [0, 0]]] }])
}
let black = ["solid": "extended-srgb:0.00000,0.00000,0.00000,1.00000"]
let doc: [String: Any] = ["groups": groups, "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
                          "fill-specializations": [["value": black], ["appearance": "dark", "value": black]]]
try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("icon.json"))
print(out.path)
