import CoreGraphics

// The drawing of the living mascot: the paths of one instant in the 100 canvas (y down) and their drawing in a CGContext,
// the same everywhere (UI, tests, video). Flat, with a 1 pt grey border around the body; the dot in front, with its border.

public struct MascotColors {
    public var body, eyes: CGColor; public var dot: CGColor?
    public init(body: CGColor, eyes: CGColor, dot: CGColor?) { self.body = body; self.eyes = eyes; self.dot = dot }
}

// The pieces of one instant.
struct MascotFigure {
    var body: CGPath
    var eyes: [CGPath]
    var dot: CGPath?    // the status dot, in front of the body
    var z: CGPath?
    var zAlpha = 0.0
    var sparkles: CGPath?
    var heart: CGPath?  // the little heart, also above the canvas (negative y)
    var heartAlpha = 0.0
}

// headroom: the units above the canvas where the little heart can rise (the view is 100 + headroom tall).
func mascotFigure(_ g: MascotGeometry, _ look: MascotLook, headroom: Double = 0) -> MascotFigure {
    // the body: squashed or stretched from the base (which stays on the ground), tilted around the base, lifted
    let sx = 1 + (1 - look.squash) * 0.6
    let t = CGAffineTransform(translationX: 0, y: -look.lift).translatedBy(x: 50, y: 90)
        .rotated(by: look.tilt).scaledBy(x: sx, y: look.squash).translatedBy(x: -50, y: -90)
    // The "z" and sparkles follow hop and tilt, not the squashing.
    let td = CGAffineTransform(translationX: 0, y: -look.lift).translatedBy(x: 50, y: 90)
        .rotated(by: look.tilt).translatedBy(x: -50, y: -90)
    let body = moved(g.shape.body, t)
    // the face scrolls with the gaze (eyePlace)
    let gx = look.gazeX, p = min(max(look.dot, 0), 1.2)
    var face = CGPoint(x: 50 + gx * g.faceX, y: g.eyeY + look.gazeY * g.faceY)
    let k = g.eyes.size   // the size slider
    func sized(_ pose: EyePose) -> EyePose { EyePose(w: pose.w * k, h: pose.h * k, bend: pose.bend, lid: pose.lid) }
    func eye(_ s: Double, _ pose: EyePose, _ d: CGVector) -> CGPath {
        let at = eyePlace(side: s, gaze: gx, face: face, gap: g.eyeGap, drift: d)
        return eyePath(sized(pose), center: at.center, widthScale: at.squeeze)
    }
    if p > 0.01 {   // the eyes make room for the dot (dotNudge)
        let n = dotNudge(eyeBox: eye(1, look.right, look.rightShift).boundingBoxOfPath, dot: g.shape.dotCenter, p: p)
        face.x += n.dx; face.y += n.dy
    }
    let sides = [(-1.0, look.left, look.leftShift), (1.0, look.right, look.rightShift)]
    var eyes: [CGPath]
    if look.turn > 0, look.turn < 1 {
        // the spin on itself (like Grok): the outline stays still and the eyes go around the head, around the cylinder as
        // wide as it is at eye height (head, spunEye)
        let places = sides.map { (eyePlace(side: $0.0, gaze: gx, face: face, gap: g.eyeGap, drift: $0.2), sized($0.1)) }
        let reach = places.map { $0.1.h / 2 + 1.3 }.max()!, ys = places.map(\.0.center.y)   // half the height plus the arches' curve
        let head = g.shape.head(ys.min()! - reach, ys.max()! + reach)
        eyes = places.compactMap { at, pose in
            let w = max(pose.w * at.squeeze, 0.6), x = at.center.x
            guard let (l, r) = spunEye(left: x - w / 2, right: x + w / 2, axis: head.axis, radius: head.radius, angle: 2 * .pi * look.turn)
            else { return nil }
            return moved(eyePath(pose, center: CGPoint(x: (l + r) / 2, y: at.center.y), widthScale: (r - l) / pose.w), t)
        }
    } else {
        eyes = sides.map { moved(eye($0, $1, $2), t) }
    }
    if let d = look.dizzy {   // dizzy: in place of the eyes two spirals turning in opposite directions
        eyes = eyes.enumerated().map { i, e in
            let b = e.boundingBoxOfPath
            return spiral(CGPoint(x: b.midX, y: b.midY), d, direction: i == 0 ? 1 : -1, size: k)
        }
    }
    var fig = MascotFigure(body: body, eyes: eyes)
    if p > 0.01 {   // the dot in front of the body, still even in the spin: it grows from nothing with a little bounce (the model's spring)
        let c = g.shape.dotCenter, r = MascotKind.dotRadius * p
        fig.dot = moved(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil), t)
    }
    if let q = look.z {   // the "z" rises from the body's top corner, towards the front, and fades
        let size = 11 + 4 * q
        fig.z = moved(zGlyph, CGAffineTransform(translationX: 84 + 4 * q, y: 30 - 8 * q).scaledBy(x: size, y: size).concatenating(td))
        fig.zAlpha = sin(.pi * min(max(q, 0), 1))
    }
    if let q = look.sparkle {   // four sparkles around the body, one after the other (like the prototype)
        let b = g.shape.body.boundingBoxOfPath, out = CGMutablePath()
        let spots = [CGPoint(x: b.minX - 4, y: b.minY + 4), CGPoint(x: b.maxX + 2, y: b.minY - 2),
                     CGPoint(x: b.maxX + 5, y: b.midY + 8), CGPoint(x: b.minX - 6, y: b.midY + 12)]
        for (k, s) in spots.enumerated() {
            let qq = min(1, max(0, q * 1.3 - Double(k) * 0.1))
            if qq > 0 { out.addPath(star(CGPoint(x: min(max(s.x, 5), 95), y: min(max(s.y, 5), 92)), 6 * sin(.pi * qq))) }
        }
        fig.sparkles = moved(out, td)
    }
    if let h = look.heart {   // the little heart: centred above the head, tip resting; it pops out with a bounce, rises slightly, fades
        let top = g.shape.body.boundingBoxOfPath
        let pop = h < 0.18 ? 0.3 + 0.95 * h / 0.18 : 1.25 - 0.25 * min(1, (h - 0.18) / 0.12)
        let half = CGSize(width: 14.8 * pop, height: 12.95 * pop)   // 8 × 7 pt at size 100%
        // rises by 1.5 pt, but with its border (1 pt) it never leaves the space above the canvas: with big mascots it rises less
        let y = max(top.minY - 12.5 - 5.5 * h - look.lift, -headroom + half.height + 1 / 0.27)
        fig.heart = heartPath(CGRect(x: top.midX - half.width, y: y - half.height, width: 2 * half.width, height: 2 * half.height))
        fig.heartAlpha = h < 0.6 ? 1 : 1 - (h - 0.6) / 0.4
    }
    return fig
}

// Where an eye sits (side -1 the left, 1 the right) and how much it narrows: the face scrolls with the gaze, the eye on the
// side it looks towards narrows as on a curved surface and the two come a little closer. The same rule for drawing
// (mascotFigure) and for the scroll that keeps the eyes inside the outline (MascotGeometry).
func eyePlace(side: Double, gaze gx: Double, face: CGPoint, gap: Double, drift: CGVector) -> (center: CGPoint, squeeze: Double) {
    (CGPoint(x: face.x + side * gap * (1 - 0.1 * abs(gx)) + drift.dx, y: face.y + drift.dy), 1 - (side * gx > 0 ? 0.25 : 0.06) * abs(gx))
}

// An eye in the spin on itself: its two edges (left, right) are points of a vertical cylinder (the head's axis and radius,
// head) that turns by `angle` towards the front (right, before mirroring the mascot). The front part is visible: towards
// the edge it narrows, then goes behind (nil) and comes back narrow from the opposite edge; after a full turn it is where it
// was. An edge that at rest is already beyond the cylinder (big eyes, at the sliders' extremes) keeps its offset: so the
// first and last instants are the still figure, and the edge never goes beyond where it sits at rest, inside the outline.
// The others do not leave the cylinder, so neither do they leave the outline.
func spunEye(left: Double, right: Double, axis cx: Double, radius r: Double, angle: Double) -> (left: Double, right: Double)? {
    guard r > 0 else { return nil }
    func edge(_ x: Double) -> (angle: Double, offset: Double) {
        let a = asin(min(max((x - cx) / r, -1), 1))
        return (a + angle, x - cx - r * sin(a))   // the offset is zero if the edge is on the cylinder
    }
    let lo = edge(left), hi = edge(right)
    for front in [0.0, 2 * .pi] {   // the front, before and after the full turn
        let l = max(lo.angle, front - .pi / 2), h = min(hi.angle, front + .pi / 2)
        if l < h { return (cx + r * sin(l) + lo.offset, cx + r * sin(h) + hi.offset) }
    }
    return nil
}

// The eyes make room for the big dot `p`, as in Grok: if the right eye's box reaches the circle or its 1 pt ring (plus half
// a unit of breathing room), the whole face moves aside, along the line from the dot's centre, by as much as is missing.
// The dot's bounce when it appears (`p` up to about 1.13) does not push further: the eye sliders are checked with the dot
// at 1 (eyesFitWithDot), beyond that the eyes could leave the outline.
func dotNudge(eyeBox b: CGRect, dot c: CGPoint, p: Double) -> CGVector {
    let q = CGPoint(x: min(max(c.x, b.minX), b.maxX), y: min(max(c.y, b.minY), b.maxY))   // the point of the box nearest
    let d = hypot(q.x - c.x, q.y - c.y), room = MascotKind.dotRadius * min(p, 1) + 1 / 0.27 + 0.5
    guard d > 0 && d < room else { return .zero }
    return CGVector(dx: (q.x - c.x) / d * (room - d), dy: (q.y - c.y) / d * (room - d))
}

// The grey of the mascots' border: generic, ≈ 0.68 in sRGB; drawn at 60%.
let mascotBorderGray = CGColor(gray: 0.62, alpha: 1)

// Draws one instant in a context with y down, in points: the 100 canvas is as tall as `size`, centred in width.
// Mirrored, the front goes to the left. With headroom the view is taller: the 100 canvas stays as tall as before and moves
// down by headroom units (the little heart rises above).
public func drawMascot(_ g: MascotGeometry, _ look: MascotLook, _ colors: MascotColors, in ctx: CGContext, size: CGSize, mirrored: Bool, headroom: Double = 0) {
    let fig = mascotFigure(g, look, headroom: headroom), s = size.height / (100 + headroom)
    ctx.saveGState()
    if mirrored { ctx.translateBy(x: size.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
    ctx.translateBy(x: (size.width - 100 * s) / 2, y: headroom * s)
    ctx.scaleBy(x: s, y: s)
    func fill(_ paths: [CGPath], _ color: CGColor) { ctx.setFillColor(color); for p in paths { ctx.addPath(p); ctx.fillPath() } }
    // the border: a path filled and stroked with a line 2 / 0.27 canvas units wide (2 pt at bar size, 27 pt tall: 1 stays
    // outside), grey at 60% in a single layer, so fill and line do not add up. Each path has its own; the dot's sits in a
    // ring cut out of the body, so it looks like the body's
    let gray = mascotBorderGray
    func border(_ path: CGPath) {
        ctx.setAlpha(0.6)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(gray); ctx.setStrokeColor(gray); ctx.setLineWidth(2 / 0.27); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.drawPath(using: .fillStroke)
        ctx.endTransparencyLayer()
        ctx.setAlpha(1)
    }
    // The whole mascot in one layer: so the cut around the dot punches only it, not what is underneath.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    border(fig.body)
    fill([fig.body], colors.body)
    fill(fig.eyes, colors.eyes)
    if let dot = fig.dot, let color = colors.dot {
        // the dot in front, separated from the body by a 1 pt ring where the background shows with the grey over it: the
        // same border as the body (over black the grey alone looked darker)
        ctx.setBlendMode(.clear)
        ctx.addPath(dot); ctx.setLineWidth(2 / 0.27); ctx.drawPath(using: .fillStroke)
        ctx.setBlendMode(.normal)
        border(dot)
        fill([dot], color)
    }
    if let z = fig.z { fill([z], CGColor(srgbRed: 0.7, green: 0.8, blue: 1, alpha: fig.zAlpha)) }
    if let sp = fig.sparkles { fill([sp], CGColor(srgbRed: 1, green: 0.85, blue: 0.35, alpha: 1)) }
    if let heart = fig.heart {   // the pink little heart with its border, fading all together
        ctx.saveGState()
        ctx.setAlpha(fig.heartAlpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        border(heart)
        fill([heart], CGColor(srgbRed: 1, green: 0.42, blue: 0.55, alpha: 1))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// A point of the view (y down) in the canvas, with the front on the right even when the mascot is mirrored; with headroom
// the canvas sits below the extra space (drawMascot).
public func canvasPoint(_ p: CGPoint, size: CGSize, mirrored: Bool, headroom: Double = 0) -> CGPoint {
    let s = size.height / (100 + headroom), ox = (size.width - 100 * s) / 2
    return CGPoint(x: ((mirrored ? size.width - p.x : p.x) - ox) / s, y: p.y / s - headroom)
}

// An eye: the little bar (rounded rectangle) with the lid cutting its top and the curve bending it into an arch. The path's
// points are deformed, so every shape flows into the other without jumps.
func eyePath(_ p: EyePose, center c: CGPoint, widthScale k: Double) -> CGPath {
    let w = max(p.w * k, 0.6), h = max(p.h, 0.6), r = min(w, h) / 2 - 0.001
    let box = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    let top = -h / 2 + p.lid * h
    func deform(_ q: CGPoint) -> CGPoint {
        let u = q.x / (w / 2)
        return CGPoint(x: c.x + q.x, y: c.y + max(q.y, top) - 1.3 * p.bend * (1 - u * u))
    }
    let out = CGMutablePath()
    var last = CGPoint.zero
    box.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: out.move(to: deform(pts[0])); last = pts[0]
        case .addLineToPoint:   // a long side in short pieces, so it bends with the other points
            let n = max(1, Int((hypot(pts[0].x - last.x, pts[0].y - last.y) / 0.4).rounded(.up)))
            for i in 1...n {
                let t = Double(i) / Double(n)
                out.addLine(to: deform(CGPoint(x: last.x + (pts[0].x - last.x) * t, y: last.y + (pts[0].y - last.y) * t)))
            }
            last = pts[0]
        case .addCurveToPoint: out.addCurve(to: deform(pts[2]), control1: deform(pts[0]), control2: deform(pts[1])); last = pts[2]
        case .closeSubpath: out.closeSubpath()
        default: break   // a rounded rectangle has only points, lines, cubic curves and closing
        }
    }
    return out
}

public func cgColor(hex v: Int) -> CGColor {
    CGColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
}

// Between two sRGB colours (the dot changing state fades).
func mixColor(_ a: CGColor, _ b: CGColor, _ t: Double) -> CGColor {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let x = a.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
          let y = b.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, x.count == 4, y.count == 4 else { return b }
    let k = min(max(t, 0), 1)
    return CGColor(srgbRed: x[0] + (y[0] - x[0]) * k, green: x[1] + (y[1] - x[1]) * k, blue: x[2] + (y[2] - x[2]) * k, alpha: 1)
}

func moved(_ p: CGPath, _ t: CGAffineTransform) -> CGPath {
    var t = t
    return p.copy(using: &t)!
}

// The sleep "z" in a centred square of side 1: two bars and the diagonal, squared like the speech-bubble font.
private let zGlyph: CGPath = {
    let p = CGMutablePath()
    p.addLines(between: [(0, 0), (1, 0), (1, 0.22), (0.36, 0.78), (1, 0.78), (1, 1), (0, 1), (0, 0.78), (0.64, 0.22), (0, 0.22)]
        .map { CGPoint(x: $0.0 - 0.5, y: $0.1 - 0.5) })
    p.closeSubpath()
    return p
}()

// The prototype's sparkle (star): four soft points.
private func star(_ c: CGPoint, _ r: Double) -> CGPath {
    let k = r * 0.24, p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
    p.closeSubpath()
    return p
}

// A spiral in place of an eye (dizzy): 2.2 turns, radius 6.6 for the eyes' size, stroke 2.2, 1.6 turns a second in the
// `direction`; it appears and vanishes in the first and last 12% of the reaction. A filled path, like the eyes, so
// drawMascot fills it with the eye colour.
private func spiral(_ c: CGPoint, _ d: Double, direction: Double, size k: Double) -> CGPath {
    let grow = min(1, d / 0.12) * min(1, (1 - d) / 0.12), turns = 2.2, r = 6.6 * k * grow
    let spin = d * MascotLife.dizzyTime * 1.6 * 2 * .pi * direction
    let p = CGMutablePath()
    for i in 0...60 {
        let th = Double(i) / 60 * turns * 2 * .pi, q = r * Double(i) / 60
        let pt = CGPoint(x: c.x + q * cos(th + spin), y: c.y + q * sin(th + spin))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    return p.copy(strokingWithWidth: max(2.2 * k * grow, 0.01), lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// The little heart in the rect r (y down): two round lobes on top and the tip at the bottom.
private func heartPath(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), w = r.width, h = r.height, x = r.minX, y = r.minY
    p.move(to: CGPoint(x: x + w / 2, y: y + h))
    p.addCurve(to: CGPoint(x: x, y: y + h * 0.32), control1: CGPoint(x: x + w * 0.2, y: y + h * 0.78), control2: CGPoint(x: x, y: y + h * 0.58))
    p.addArc(center: CGPoint(x: x + w * 0.25, y: y + h * 0.3), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
    p.addArc(center: CGPoint(x: x + w * 0.75, y: y + h * 0.3), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
    p.addCurve(to: CGPoint(x: x + w / 2, y: y + h), control1: CGPoint(x: x + w, y: y + h * 0.58), control2: CGPoint(x: x + w * 0.8, y: y + h * 0.78))
    p.closeSubpath()
    return p
}

/// How to draw a mascot so its BODY fills an `avatar` pt square (aspect kept, centred), like a round profile picture.
/// The canvas is 100 units drawn at `size`; the view is the avatar plus `inset` on every side (room for hops, "z", sparkles),
/// and the drawing is translated by `offset` inside it. The canvas units are wider than tall by the bar ratio (31.5 : 27).
public func avatarLayout(_ g: MascotGeometry, avatar: CGFloat, inset: CGFloat = 0) -> (size: CGSize, offset: CGPoint) {
    let box = g.shape.body.boundingBoxOfPath, ratio = 31.5 / 27.0
    let u = avatar / max(box.width * ratio, box.height)    // pt per canvas unit vertically
    let sx = u * ratio, sy = u
    return (CGSize(width: 100 * sx, height: 100 * sy),
            CGPoint(x: inset + avatar / 2 - box.midX * sx, y: inset + avatar / 2 - box.midY * sy))
}
