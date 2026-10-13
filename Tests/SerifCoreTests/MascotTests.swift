import CoreGraphics
import Foundation
import XCTest
@testable import SerifCore

// Ported from Siigil's mascot tests (pure parts only), adapted to BotFace.

private extension ClosedRange where Bound == Double { var bounds: [Double] { [lowerBound, upperBound] } }

// `seconds` seconds in 1/60 s steps (like the view) with the same input; `each` sees every instant.
private func live(_ life: inout MascotLife, _ input: MascotInput, _ seconds: Double, each: (MascotLook) -> Void = { _ in }) {
    for _ in 0..<Int((seconds * 60).rounded()) { life.advance(1.0 / 60, input: input); each(life.look) }
}

// Average redraws per second over 10 minutes of a state, with the view's two rhythms and the `shouldRedraw` rule.
private func redrawsPerSecond(_ kind: MascotKind, _ input: MascotInput) -> Double {
    var life = MascotLife(kind: kind, seed: 7)
    life.advance(5, input: input)
    var drawn = life.look, count = 0, t = 0.0
    while t < 600 {
        let dt = 1 / (life.fastFrames ? MascotLife.fastFPS : MascotLife.calmFPS)
        life.advance(dt, input: input); t += dt
        if shouldRedraw(drawn, life) { drawn = life.look; count += 1 }
    }
    return Double(count) / 600
}

// The three eye sliders' extremes for a shape, plus the centre.
private func extremes(_ shape: MascotKind) -> [EyeSettings] {
    let r = EyeRanges.of(shape)
    return [EyeSettings()] + r.sizes.bounds.flatMap { size in
        r.lifts.bounds.flatMap { lift in r.spreads.bounds.map { EyeSettings(size: size, lift: lift, spread: $0) } }
    }
}

final class MascotTests: XCTestCase {
    func testRandomFaceAvoidsUsedBodyColours() {
        var rng = SplitMix(seed: 7)
        var faces: [BotFace] = []
        for _ in 0..<6 { faces.append(randomFace(existing: faces, using: &rng)) }
        XCTAssertEqual(Set(faces.map(\.body)).count, faces.count)
    }

    // Past the 12 swatches, Siigil's rule applies: no repeated shape + body + eyes combination.
    func testRandomFaceFallsBackToDistinctCombinations() {
        var rng = SplitMix(seed: 7)
        var faces: [BotFace] = []
        for _ in 0..<30 { faces.append(randomFace(existing: faces, using: &rng)) }
        XCTAssertEqual(Set(faces.map { "\($0.shape.rawValue)-\($0.body)-\($0.eyes)" }).count, faces.count)
        XCTAssertEqual(Set(faces.prefix(12).map(\.body)).count, 12)
    }

    func testDrawMascotRendersSomething() {
        let face = BotFace(shape: .allCases[0], body: 0x6BC4A6, eyes: 0x14141A)
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = MascotGeometry.of(face)
        let life = MascotLife(kind: face.shape, seed: 1)
        drawMascot(g, life.look, MascotColors(body: cgColor(hex: face.body), eyes: cgColor(hex: face.eyes), dot: nil),
                   in: ctx, size: CGSize(width: 64, height: 64), mirrored: false)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertTrue((0..<64*64).contains { data[$0 * 4 + 3] > 0 })   // some opaque pixel
    }

    func testRandomFaceIsRepeatableWithAFixedGenerator() {
        var a = SplitMix(seed: 3), b = SplitMix(seed: 3)
        XCTAssertEqual(randomFace(existing: [], using: &a), randomFace(existing: [], using: &b))
    }

    func testSpringsSettleWithoutOvershootWhenCriticallyDamped() {
        var s = MascotSpring(0, omega: 20); s.target = 1
        var peak = 0.0
        for _ in 0..<240 { s.step(1.0 / 120); peak = max(peak, s.x) }
        XCTAssertTrue(peak <= 1.001 && s.still(0.001))
        var b = MascotSpring(0, omega: 20, zeta: 0.4); b.target = 1
        peak = 0
        for _ in 0..<240 { b.step(1.0 / 120); peak = max(peak, b.x) }
        XCTAssertGreaterThan(peak, 1.1)   // below critical damping it bounces
    }

    func testSameSeedSameLife() {
        func run(_ seed: UInt64) -> [MascotLook] {
            var life = MascotLife(kind: .mirtillo, seed: seed), out: [MascotLook] = []
            for mood in [MascotMood.sleep, .watch, .alarm, .sleep] {
                live(&life, MascotInput(mood: mood, dot: mood == .alarm), 15) { out.append($0) }
            }
            return out
        }
        XCTAssertTrue(run(9) == run(9) && run(9) != run(10))
    }

    func testLongPausesSkipAheadWithoutPhysics() {
        var life = MascotLife(kind: .mostro, seed: 8)
        let start = Date()
        life.advance(3600, input: MascotInput(mood: .sleep))
        XCTAssertTrue(Date().timeIntervalSince(start) < 5 && abs(life.time - 3600) < 0.01)
        XCTAssertTrue(life.look.left.bend < -0.9 || life.look.left.h > 10)   // a valid instant: asleep or peeking
    }

    func testRedrawBudget() {
        for kind in MascotKind.allCases {
            let sleep = redrawsPerSecond(kind, MascotInput(mood: .sleep))
            XCTAssertLessThan(sleep, 5, "\(kind) asleep")
            for mood in [MascotMood.work, .wait, .done, .watch, .alarm] {
                let r = redrawsPerSecond(kind, MascotInput(mood: mood, dot: true))
                XCTAssertLessThan(r, 10, "\(kind) \(mood)")
            }
        }
    }

    func testTodaysTwoShapesKeepTheirLook() {
        let mostro = MascotGeometry.of(.mostro), mirtillo = MascotGeometry.of(.mirtillo)
        XCTAssertTrue(abs(mostro.eyeY - 50.32) < 1e-9 && mostro.eyeGap == 12.6 && mostro.faceX == 17.5 && mostro.faceY == 6)
        XCTAssertTrue(abs(mirtillo.eyeY - 62.72) < 1e-9 && mirtillo.eyeGap == 11 && mirtillo.faceX == 21.5 && mirtillo.faceY == 6)
    }

    func testEveryShapeKeepsItsFaceScroll() {
        let sideways: [MascotKind: Double] = [.mostro: 17.5, .mirtillo: 21.5, .ball: 10, .pebble: 14, .squircle: 13.5, .capsule: 24.5,
                                              .hexagon: 13, .cloud: 19, .drop: 20.5]
        for shape in MascotKind.allCases {
            let g = MascotGeometry.of(shape)
            XCTAssertTrue(g.faceX == sideways[shape] && g.faceY == 6, "\(shape): \(g.faceX), \(g.faceY)")
        }
    }

    // In every shape, at every slider extreme, the eyes stay inside the outline over the whole gaze grid, in every pose,
    // with full drift; also when they make room for the dot.
    func testEveryShapeKeepsItsEyesInsideAtEveryExtreme() {
        for shape in MascotKind.allCases {
            for eyes in extremes(shape) {
                let g = MascotGeometry.of(shape, eyes)
                for gx in stride(from: -1.0, through: 1, by: 0.25) {
                    for gy in stride(from: -1.0, through: 1, by: 0.5) {
                        for pose in eyePoses {
                            for dot in [0.0, 1] {
                                var look = MascotLook(); look.gazeX = gx; look.gazeY = gy; look.left = pose; look.right = pose; look.dot = dot
                                let drift = CGVector(dx: gx < 0 ? -1 : 1, dy: gy < 0 ? -0.5 : 0.5)
                                look.leftShift = dot == 0 ? drift : CGVector(dx: -1, dy: -0.5)
                                look.rightShift = dot == 0 ? drift : CGVector(dx: 1, dy: 0.5)
                                for eye in mascotFigure(g, look).eyes where !inside(shape.body, eye.boundingBoxOfPath) {
                                    XCTFail("\(shape) \(eyes) gaze \(gx) \(gy) \(pose) dot \(dot): eye outside")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Every shape sits in the canvas: rests on the ground (90), stays inside, the dot sits on the lower front edge, "z" and
    // sparkles are drawn inside.
    func testEveryShapeSitsInTheCanvas() {
        for shape in MascotKind.allCases {
            let g = MascotGeometry.of(shape), b = shape.body.boundingBoxOfPath
            XCTAssertTrue(abs(b.maxY - 90) < 1e-6 && b.minY >= 15 && b.minX >= 4 && b.maxX <= 96, "\(shape) \(b)")
            var look = MascotLook(); look.dot = 0
            XCTAssertNil(mascotFigure(g, look).dot, "\(shape) dot at 0")
            look.dot = 1
            let dot = mascotFigure(g, look).dot!.boundingBoxOfPath
            XCTAssertTrue(!shape.body.contains(shape.dotCenter) && shape.body.contains(CGPoint(x: dot.minX + 2, y: dot.midY)), "\(shape) dot")
            look.dot = 1.13
            let big = mascotFigure(g, look).dot!.boundingBoxOfPath.insetBy(dx: -3.7, dy: -3.7)
            XCTAssertTrue(big.maxX <= 108.3 && big.maxY <= 100, "\(shape) \(big)")
            look = MascotLook(); look.z = 1; look.sparkle = 0.5
            let fig = mascotFigure(g, look)
            for p in [fig.z!, fig.sparkles!] {
                let r = p.boundingBoxOfPath
                XCTAssertTrue(r.minX >= -8.3 && r.maxX <= 108.3 && r.minY >= 0 && r.maxY <= 100, "\(shape) \(r)")
            }
        }
    }

    func testEyeRangesContainTheCentreAndEveryCombinationFitsAtRest() {
        for shape in MascotKind.allCases {
            let r = EyeRanges.of(shape)
            XCTAssertTrue(r.sizes.contains(1) && r.lifts.contains(0) && r.spreads.contains(1), "\(shape)")
            for s in [r.sizes.lowerBound, 1, r.sizes.upperBound] {
                for p in [r.spreads.lowerBound, 1, r.spreads.upperBound] {
                    for l in stride(from: r.lifts.lowerBound, through: r.lifts.upperBound, by: 1)
                    where !eyesFitAtRest(shape, EyeSettings(size: s, lift: l, spread: p)) {
                        XCTFail("\(shape): size \(s), lift \(l), spread \(p) does not fit")
                    }
                }
            }
        }
    }

    func testSavedEyeValuesAreClampedToTheRanges() {
        let face = BotFace(shape: .ball, body: 0, eyes: 0, eyeSize: 5, eyeLift: -40, eyeSpread: 0.1)
        let e = EyeSettings(face), r = EyeRanges.of(.ball)
        XCTAssertTrue(e.size == r.sizes.upperBound && e.lift == r.lifts.lowerBound && e.spread == r.spreads.lowerBound)
    }

    func testVisibleDistanceIsInPoints() {
        let a = MascotLook()
        XCTAssertEqual(visibleDistance(a, a, .of(.mostro)), 0)
        var b = a; b.gazeX = 1
        XCTAssertEqual(visibleDistance(a, b, .of(.mirtillo)), MascotGeometry.of(.mirtillo).faceX * 0.27, accuracy: 1e-9)
        b = a; b.z = 0.5
        XCTAssertEqual(visibleDistance(a, b, .of(.mostro)), .infinity)   // an appearing "z" is always drawn
    }

    func testGazeAndArchesGoTheRightWay() {
        var look = MascotLook(); look.left = .open; look.right = .open
        let rest = mascotFigure(.of(.mirtillo), look).eyes.map(\.boundingBoxOfPath)
        look.gazeX = 1
        let right = mascotFigure(.of(.mirtillo), look).eyes.map(\.boundingBoxOfPath)
        XCTAssertTrue(right[0].midX > rest[0].midX && right[1].midX > rest[1].midX)
        XCTAssertLessThan(right[1].width, right[0].width)
    }

    func testMascotKindRawValuesMatchSiigil() {
        XCTAssertEqual(MascotKind.allCases.map(\.rawValue), ["mostro", "mirtillo", "ball", "pebble", "squircle", "capsule", "hexagon", "cloud", "drop"])
    }
}
