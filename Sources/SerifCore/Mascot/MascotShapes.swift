import CoreGraphics
import Foundation
import SwiftUI   // Path(roundedRect:style: .continuous): the soft corners of the square and the capsule, like the prototype

// The mascot shapes: the prototype's outlines (bodyPath) in the 100 canvas (y down), in the box 8…92 × 28…90, all resting
// on the ground (90) like the two original ones (breath, jumps and crouches start from the base). Like Grok's shapes: no
// upside-down triangle, the new squircle and the redone pebble; the hexagon is a rounded polygon. For each one, where
// the eyes (fitEyes) and the dot sit.
extension MascotKind {
    var body: CGPath { Self.bodies[self]! }
    static let dotRadius = 12.0
    var dotCenter: CGPoint { Self.dots[self]! }

    // The shape's eyes before the sliders: the height of the centre (the prototype's fitEyes, 28 + 62 × the fraction: 0.36 for
    // Mostro, 0.56 for the others) and half the distance (Mostro 12.6 and Mirtillo 11.0 as today; the others like
    // Mirtillo, so the closed arches stay apart).
    var eyeSpot: (y: Double, gap: Double) {
        switch self {
        case .mostro: (28 + 62 * 0.36, 12.6)
        default: (28 + 62 * 0.56, 11.0)
        }
    }

    private static let bodies = Dictionary(uniqueKeysWithValues: allCases.map { ($0, grounded(shapePath($0))) })
    private static let dots = Dictionary(uniqueKeysWithValues: allCases.map { ($0, dotSpot(bodies[$0]!)) })

    private static func shapePath(_ k: MascotKind) -> CGPath {
        switch k {
        case .mostro:   // the "monster" stretched down to the ground
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 22, y: 31))
            p.addQuadCurve(to: CGPoint(x: 78, y: 31), control: CGPoint(x: 50, y: 25))
            p.addQuadCurve(to: CGPoint(x: 89, y: 44), control: CGPoint(x: 89, y: 32))
            p.addCurve(to: CGPoint(x: 68, y: 80), control1: CGPoint(x: 89, y: 62), control2: CGPoint(x: 82, y: 78))
            p.addQuadCurve(to: CGPoint(x: 32, y: 80), control: CGPoint(x: 50, y: 84))
            p.addCurve(to: CGPoint(x: 11, y: 44), control1: CGPoint(x: 18, y: 78), control2: CGPoint(x: 11, y: 62))
            p.addQuadCurve(to: CGPoint(x: 22, y: 31), control: CGPoint(x: 11, y: 32))
            p.closeSubpath()
            return moved(p, CGAffineTransform(translationX: 0, y: 25).scaledBy(x: 1, y: 65.0 / 57).translatedBy(x: 0, y: -25))
        case .mirtillo:   // soft square, roundness 0.88
            return Path(roundedRect: CGRect(x: 8, y: 28, width: 84, height: 62), cornerRadius: 0.88 * 62 / 2, style: .continuous).cgPath
        case .ball:
            return CGPath(ellipseIn: CGRect(x: 16, y: 22, width: 68, height: 68), transform: nil)
        case .pebble:   // an irregular oval like Grok's pebble: wider than tall, full at the top left, flatter
            // below, tilted 10° (the right lower)
            // 24 points joined by soft curves (Catmull-Rom): few segments, so checking whether a point is inside is cheap
            let tilt = 10 * Double.pi / 180, n = 24
            let pts = (0..<n).map { i -> CGPoint in
                let th = Double(i) / Double(n) * 2 * .pi, c = cos(th), s = sin(th)
                let k = 1 + 0.07 * cos(th + 2.3) + 0.025 * cos(2 * th - 0.6)   // the bump at the top left
                let x = 38 * k * c, y = 31 * k * s * (s > 0 ? 1 - 0.16 * s * s : 1)   // y down: s > 0 is below, flattened
                return CGPoint(x: 50 + x * cos(tilt) - y * sin(tilt), y: 59 + x * sin(tilt) + y * cos(tilt))
            }
            let p = CGMutablePath()
            p.move(to: pts[0])
            for i in 0..<n {
                let a = pts[(i + n - 1) % n], b = pts[i], c = pts[(i + 1) % n], d = pts[(i + 2) % n]
                p.addCurve(to: c, control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                           control2: CGPoint(x: c.x - (d.x - b.x) / 6, y: c.y - (d.y - b.y) / 6))
            }
            p.closeSubpath()
            return moved(p, CGAffineTransform(translationX: 50 - p.boundingBoxOfPath.midX, y: 0))   // centred like the others
        case .squircle:   // a square with continuous corners, like Grok's squircle: as wide as the ball
            return Path(roundedRect: CGRect(x: 18, y: 26, width: 64, height: 64), cornerRadius: 20, style: .continuous).cgPath
        case .capsule:
            return Path(roundedRect: CGRect(x: 5, y: 35, width: 90, height: 55), cornerRadius: 27.5, style: .continuous).cgPath
        case .hexagon:   // a polygon with rounded corners (the prototype's roundedPoly), from the middle of the top left side
            let pts = [CGPoint(x: 29, y: 28), CGPoint(x: 71, y: 28), CGPoint(x: 92, y: 59), CGPoint(x: 71, y: 90),
                       CGPoint(x: 29, y: 90), CGPoint(x: 8, y: 59)], p = CGMutablePath()
            p.move(to: CGPoint(x: 18.5, y: 43.5))
            for i in pts.indices { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count], radius: 12) }
            p.closeSubpath()
            return p
        case .cloud:   // three round bumps over a flat base
            var p = CGPath(roundedRect: CGRect(x: 10, y: 54, width: 80, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil)
            for (x, y, r) in [(31.0, 56.0, 19.0), (53.0, 45.0, 23.0), (73.0, 57.0, 17.0)] {
                p = p.union(CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil))
            }
            return p
        case .drop:   // the tip at the top
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 50, y: 20))
            p.addCurve(to: CGPoint(x: 92, y: 67.68), control1: CGPoint(x: 66.8, y: 26.2), control2: CGPoint(x: 92, y: 41.08))
            p.addCurve(to: CGPoint(x: 50, y: 90), control1: CGPoint(x: 92, y: 87.52), control2: CGPoint(x: 78.56, y: 90))
            p.addCurve(to: CGPoint(x: 8, y: 67.68), control1: CGPoint(x: 21.44, y: 90), control2: CGPoint(x: 8, y: 87.52))
            p.addCurve(to: CGPoint(x: 50, y: 20), control1: CGPoint(x: 8, y: 41.08), control2: CGPoint(x: 33.2, y: 26.2))
            p.closeSubpath()
            return p
        }
    }

    // The head space between heights y0…y1, where it is wide enough on every row: the axis and half the width, minus 1
    // unit of margin (like eyesFit). The cylinder the eyes go around in the spin on itself (spunEye).
    func head(_ y0: Double, _ y1: Double) -> (axis: Double, radius: Double) {
        let band = Self.rows[self]![max(Int(y0.rounded(.down)), 0)...min(Int(y1.rounded(.up)), 100)]
        guard band.allSatisfy({ $0 != nil }) else { return (50, 0) }
        let l = band.map { $0!.lowerBound }.max()!, r = band.map { $0!.upperBound }.min()!
        return ((l + r) / 2, (r - l) / 2 - 1)
    }

    // The outline row by row, at every canvas unit from the top: from where to where it is inside around the centre (x 50); nil
    // where the centre is outside. Computed once for all shapes, on first use (~5 ms).
    private static let rows = Dictionary(uniqueKeysWithValues: allCases.map { k in (k, (0...100).map { span(bodies[k]!, Double($0)) }) })

    private static func span(_ body: CGPath, _ y: Double) -> ClosedRange<Double>? {
        guard body.contains(CGPoint(x: 50, y: y)) else { return nil }
        func edge(_ dir: Double) -> Double {   // in steps of 2 while inside, then six halvings: to a thirty-second of a unit
            var inside = 50.0, outside = 50 + 2 * dir
            while (0...100).contains(outside), body.contains(CGPoint(x: outside, y: y)) { inside = outside; outside += 2 * dir }
            for _ in 0..<6 { let mid = (inside + outside) / 2; if body.contains(CGPoint(x: mid, y: y)) { inside = mid } else { outside = mid } }
            return inside
        }
        return edge(-1)...edge(1)
    }

    // On the ground: the lowest point at 90.
    private static func grounded(_ p: CGPath) -> CGPath { moved(p, CGAffineTransform(translationX: 0, y: 90 - p.boundingBoxOfPath.maxY)) }

    // Where the dot sits: on the body's edge, on the diagonal down towards the front (30° below horizontal), with its
    // centre just outside: it covers the corner without reaching the eyes.
    private static func dotSpot(_ body: CGPath) -> CGPoint {
        let c = CGPoint(x: 50, y: 59), dir = CGVector(dx: cos(0.52), dy: sin(0.52))
        var t = 0.0
        while body.contains(CGPoint(x: c.x + dir.dx * t, y: c.y + dir.dy * t)) { t += 0.25 }
        t += 0.2 * dotRadius
        return CGPoint(x: c.x + dir.dx * t, y: c.y + dir.dy * t)
    }
}

// The three eye sliders: size and distance as factors, height in canvas units (up if positive). How far they go is
// decided by the shape (EyeRanges).
public struct EyeSettings: Hashable, Sendable {
    public var size = 1.0, lift = 0.0, spread = 1.0
    public init(size: Double = 1.0, lift: Double = 0.0, spread: Double = 1.0) { self.size = size; self.lift = lift; self.spread = spread }
}

extension EyeSettings {
    // Saved values brought back into the shape's ranges (hand-written, from another version or with another shape): the
    // eyes stay inside the outline.
    public init(_ face: BotFace) {
        let r = EyeRanges.of(face.shape)
        self.init(size: clamped(face.eyeSize, to: r.sizes, default: 1), lift: clamped(face.eyeLift, to: r.lifts, default: 0),
                  spread: clamped(face.eyeSpread, to: r.spreads, default: 1))
    }
}

// A number brought back into its limits; absent = the default.
func clamped(_ value: Double?, to range: ClosedRange<Double>, default fallback: Double) -> Double {
    guard let value else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}

// How far a shape's eye sliders go: the widest box of size × height × distance, within the limits 50–200%, ±15 units and
// 40–200%, in which every combination keeps the eyes inside the outline at rest (eyesFitAtRest); the face's scroll is then
// derived from shape and eyes, and at the extremes it can be zero. The box grows first in proportion to the limits, then
// each side as far as it can (size, distance, height), in slider steps: 1% and 1 unit. The vertices are checked: bigger
// eyes, further apart or further from the outline's centre fare worse (a test also checks inside). Computed once per shape.
struct EyeRanges: Equatable {
    let sizes: ClosedRange<Double>, lifts: ClosedRange<Double>, spreads: ClosedRange<Double>

    static func of(_ shape: MascotKind) -> EyeRanges {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[shape] { return r }
        let r = EyeRanges(shape)
        cache[shape] = r
        return r
    }
    private static var cache: [MascotKind: EyeRanges] = [:]
    private static let lock = NSLock()

    private init(_ shape: MascotKind) {
        // the box in slider steps: size and distance in %, height in units
        let caps = [50...200, 40...200, -15...15], start = [100, 100, 0]
        func fits(_ b: [ClosedRange<Int>]) -> Bool {
            for s in [b[0].lowerBound, b[0].upperBound] {
                for p in [b[1].lowerBound, b[1].upperBound] {
                    for l in [b[2].lowerBound, b[2].upperBound]
                    where !eyesFitAtRest(shape, EyeSettings(size: Double(s) / 100, lift: Double(l), spread: Double(p) / 100)) { return false }
                }
            }
            return true
        }
        var b = start.map { $0...$0 }
        if fits(b) {
            // in proportion to the limits: the longest step, in hundredths of the way to the limits, that fits
            func scaled(_ n: Int) -> [ClosedRange<Int>] {
                (0..<3).map { (start[$0] - (start[$0] - caps[$0].lowerBound) * n / 100)...(start[$0] + (caps[$0].upperBound - start[$0]) * n / 100) }
            }
            var good = 0, bad = 101
            while bad - good > 1 { let mid = (good + bad) / 2; if fits(scaled(mid)) { good = mid } else { bad = mid } }
            b = scaled(good)
            // then one side at a time, as far as it can
            for i in 0..<3 {
                for up in [false, true] {
                    func with(_ v: Int) -> [ClosedRange<Int>] { var c = b; c[i] = up ? c[i].lowerBound...v : v...c[i].upperBound; return c }
                    var good = up ? b[i].upperBound : b[i].lowerBound, bad = up ? caps[i].upperBound + 1 : caps[i].lowerBound - 1
                    while abs(bad - good) > 1 { let mid = (good + bad) / 2; if fits(with(mid)) { good = mid } else { bad = mid } }
                    b = with(good)
                }
            }
        }
        sizes = Double(b[0].lowerBound) / 100...Double(b[0].upperBound) / 100
        spreads = Double(b[1].lowerBound) / 100...Double(b[1].upperBound) / 100
        lifts = Double(b[2].lowerBound)...Double(b[2].upperBound)
    }
}

// A shape with its eyes: where they sit, how far the face scrolls with the gaze and where the dot sits. The scroll is the
// maximum that keeps the eyes inside the outline with 1 unit of margin, in all poses, with full drift and the gaze at the
// extremes, and also when the face moves aside to make room for the dot (up and down at most 6, as today), in half units:
// so Mostro and Mirtillo with the sliders centred come out as before (17.5 and 21.5). Computed once per shape and sliders
// (`of`).
public struct MascotGeometry: Equatable, Sendable {
    public let shape: MascotKind
    public let eyes: EyeSettings
    let eyeY, eyeGap, faceX, faceY: Double

    // ponytail: a cache that grows with every slider value seen (few: the sliders go in steps); empty it if they became
    // continuous.
    public static func of(_ shape: MascotKind, _ eyes: EyeSettings = EyeSettings()) -> MascotGeometry {
        let key = Key(shape: shape, eyes: eyes)
        lock.lock(); defer { lock.unlock() }
        if let g = cache[key] { return g }
        let g = MascotGeometry(shape: shape, eyes: eyes)
        cache[key] = g
        return g
    }
    private struct Key: Hashable { let shape: MascotKind; let eyes: EyeSettings }
    private static var cache: [Key: MascotGeometry] = [:]
    private static let lock = NSLock()

    private init(shape: MascotKind, eyes: EyeSettings) {
        self.shape = shape
        self.eyes = eyes
        let spot = shape.eyeSpot, y = spot.y - eyes.lift, gap = spot.gap * eyes.spread
        func fits(_ fx: Double, _ fy: Double) -> Bool {
            eyesFit(shape.body, dot: shape.dotCenter, eyeY: y, gap: gap, scale: eyes.size, faceX: fx, faceY: fy)
        }
        let fy = stride(from: 6.0, through: 0, by: -0.5).first { fits(0, $0) } ?? 0
        var fit = 0, miss = 80   // in half units: 0 is inside (the sliders' ranges guarantee it), 40 is not
        while miss - fit > 1 { let mid = (fit + miss) / 2; if fits(Double(mid) / 2, fy) { fit = mid } else { miss = mid } }
        eyeY = y; eyeGap = gap; faceY = fy; faceX = Double(fit) / 2
    }
}

// The eyes are inside the outline: with 1 unit of margin with the gaze over the whole grid, in every pose and with full
// drift; without margin when the face makes room for the dot (eyesFitWithDot, every pose). The eye boxes as mascotFigure
// places them: exact for open and wide eyes, a little generous for the bent arches.
private func eyesFit(_ body: CGPath, dot: CGPoint, eyeY: Double, gap: Double, scale: Double, faceX: Double, faceY: Double) -> Bool {
    for gx in stride(from: -1.0, through: 1, by: 0.25) {
        for gy in stride(from: -1.0, through: 1, by: 0.5) {
            let face = CGPoint(x: 50 + gx * faceX, y: eyeY + gy * faceY)
            let drift = CGVector(dx: gx < 0 ? -1 : 1, dy: gy < 0 ? -0.5 : 0.5)
            for pose in eyePoses {
                for side in [-1.0, 1.0]
                where !inside(body, eyeBox(pose, side, gx, face, drift, gap: gap, scale: scale).insetBy(dx: -1, dy: -1)) { return false }
            }
            // the dot out, on the same gaze grid (eyesFitWithDot)
            if !eyesFitWithDot(body, dot: dot, face: face, gaze: gx, gap: gap, scale: scale) { return false }
        }
    }
    return true
}

// The poses of all states: the closed arches are the widest.
let eyePoses = [EyePose.open, .wide, .half, .asleep, .happy, .wink]

// An eye's box as mascotFigure (eyePlace) places it: exact for open and wide eyes, a little generous for the bent
// arches.
private func eyeBox(_ pose: EyePose, _ side: Double, _ gx: Double, _ face: CGPoint, _ drift: CGVector, gap: Double, scale: Double) -> CGRect {
    let at = eyePlace(side: side, gaze: gx, face: face, gap: gap, drift: drift), c = at.center
    let w = max(pose.w * scale * at.squeeze, 0.6), h = max(pose.h * scale, 0.6), top = -h / 2 + pose.lid * h
    return CGRect(x: c.x - w / 2, y: c.y + top - max(0, 1.3 * pose.bend), width: w, height: h / 2 - top + abs(1.3 * pose.bend))
}

// All four corners of the box are inside the outline.
func inside(_ body: CGPath, _ r: CGRect) -> Bool {
    [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        .allSatisfy { body.contains($0) }
}

// With the dot out the face moves along the line from its centre, as in mascotFigure (dotNudge), by as much as the right
// eye asks for in its pose. In every pose (the dot can be out even while sleeping and cheering), with the right eye pushed
// by the drift towards the dot and the left one the other way, both stay inside: without margin, they are already moved
// aside. The same check for the face's scroll (eyesFit) and for the sliders (eyesFitAtRest).
private func eyesFitWithDot(_ body: CGPath, dot: CGPoint, face: CGPoint, gaze gx: Double, gap: Double, scale: Double) -> Bool {
    let toward = CGVector(dx: 1, dy: 0.5), away = CGVector(dx: -1, dy: -0.5)
    for pose in eyePoses {
        let n = dotNudge(eyeBox: eyeBox(pose, 1, gx, face, toward, gap: gap, scale: scale), dot: dot, p: 1)
        let moved = CGPoint(x: face.x + n.dx, y: face.y + n.dy)
        for (side, drift) in [(-1.0, away), (1.0, toward)]
        where !inside(body, eyeBox(pose, side, gx, moved, drift, gap: gap, scale: scale)) { return false }
    }
    return true
}

// The eyes inside the outline at rest (EyeRanges): face still and gaze straight, full drift on all sides (with the face
// still, side gazes narrow and bring the eyes closer: they are inside these), every pose, with 1 unit of margin; and
// with the dot out the face moving aside for it (eyesFitWithDot), like eyesFit.
func eyesFitAtRest(_ shape: MascotKind, _ e: EyeSettings) -> Bool {
    let body = shape.body, spot = shape.eyeSpot, gap = spot.gap * e.spread, face = CGPoint(x: 50, y: spot.y - e.lift)
    for dx in [-1.0, 1] {
        for dy in [-0.5, 0.5] {
            for pose in eyePoses {
                for side in [-1.0, 1.0]
                where !inside(body, eyeBox(pose, side, 0, face, CGVector(dx: dx, dy: dy), gap: gap, scale: e.size).insetBy(dx: -1, dy: -1)) { return false }
            }
        }
    }
    for gx in stride(from: -1.0, through: 1, by: 0.5)
    where !eyesFitWithDot(body, dot: shape.dotCenter, face: face, gaze: gx, gap: gap, scale: e.size) { return false }
    return true
}
