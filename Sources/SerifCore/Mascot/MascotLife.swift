import CoreGraphics
import Foundation

// The living mascot: the model, without drawing. Three layers, like Grok Bot: a background that never stops (breathing,
// swaying, wandering eyes: waves computed from time), gestures on a random clock (blinks, glances, peeks, hops) and
// fixed-step springs (1/120 s) that smooth every change. Random numbers come from a seeded generator: tests and the
// redraw budget always run the same.
// Everything in the prototype's canvas units: 100 = the mascot's height; y down; x towards the front (the speech
// bubble side).

// SplitMix64: repeatable random numbers.
public struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    public init(seed: UInt64) { s = seed }
    init(s: UInt64) { self.s = s }
    public mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// A spring towards `target`: with zeta 1 it arrives without overshooting, below that it bounces. Impulses (hops,
// tremors) are given on the velocity.
struct MascotSpring {
    var x: Double, v = 0.0, target: Double
    let omega: Double, zeta: Double
    init(_ x: Double, omega: Double, zeta: Double = 1) { self.x = x; target = x; self.omega = omega; self.zeta = zeta }
    mutating func step(_ h: Double) {
        v += (-2 * zeta * omega * v - omega * omega * (x - target)) * h
        x += v * h
    }
    func still(_ eps: Double) -> Bool { abs(x - target) < eps && abs(v) < eps * omega }
}

// The shape: Mostro and Mirtillo, the two original ones, and seven like Grok's, in the order they are picked (the upside-down
// triangle was removed, the squircle added). Saved by its name. Outlines, eyes and dot in MascotShapes.swift.
public enum MascotKind: String, Codable, CaseIterable, Sendable {
    case mostro, mirtillo, ball, pebble, squircle, capsule, hexagon, cloud, drop
}

// Sleeps, works, waits for you, is done (AI monitor); watches a heavy job, alarm (system monitor).
public enum MascotMood { case sleep, work, wait, done, watch, alarm }

public struct MascotInput: Equatable {
    public var mood: MascotMood
    public var dot = false        // the status dot is out
    public var hover: CGPoint?    // the pointer over the mascot, in canvas units
    public var pressed = false    // pressed with the left button: it squashes
    public init(mood: MascotMood, dot: Bool = false, hover: CGPoint? = nil, pressed: Bool = false) {
        self.mood = mood; self.dot = dot; self.hover = hover; self.pressed = pressed
    }
}

// An eye: today's little bar and its shapes. Width and height in the canvas; bend from -1 (asleep, ‿) to 1 (happy, ︵);
// lid from 0 (open) to 1 (closed from the top).
public struct EyePose: Equatable {
    public var w, h, bend, lid: Double
    public static let open = EyePose(w: 7.08, h: 15.3, bend: 0, lid: 0)
    public static let wide = EyePose(w: 8.15, h: 17.6, bend: 0, lid: 0)
    public static let half = EyePose(w: 7.08, h: 15.3, bend: 0, lid: 0.5)
    // closed eyes are bigger than before (15.5 × 4.4 instead of 12.2 × 3.2): at real size they looked small
    public static let asleep = EyePose(w: 15.5, h: 4.4, bend: -1, lid: 0)
    public static let happy = EyePose(w: 15.5, h: 4.4, bend: 1, lid: 0)
    public static let wink = EyePose(w: 15.5, h: 4.4, bend: 0.6, lid: 0)
}

// What is drawn at one instant.
public struct MascotLook: Equatable {
    public init() {}
    public var gazeX = 0.0, gazeY = 0.0              // -1…1: x towards the front, y down
    public var squash = 1.0                          // body height (width does the opposite, the base stays on the ground)
    public var tilt = 0.0                            // radians, around the centre of the base
    public var lift = 0.0                            // from the ground, in canvas units
    public var left = EyePose.asleep, right = EyePose.asleep
    public var leftShift = CGVector.zero, rightShift = CGVector.zero   // each eye wanders a little on its own, in canvas units
    public var dot = 0.0                             // dot: size, 0 gone, 1 whole (a bit more with the bounce)
    public var dotFade = 1.0                         // from the previous colour (0) to the new one (1)
    public var z: Double?                            // the rising "z", 0…1
    public var sparkle: Double?                      // the sparkles, 0…1
    public var turn = 0.0                            // the spin on itself, 0…1: the eyes go around the head, halfway they are behind
    public var heart: Double?                        // the little heart after 4 quick clicks, 0…1
    public var dizzy: Double?                        // spiral eyes after 4 quick clicks, 0…1
}

// The redraw step: with the background alone a tenth of a point, so the sway flows smoothly and not in half-pixel nudges;
// in fast gestures, at 60 images a second, a quarter is enough.
let visibleStep = 0.1, fastStep = 0.25

// How visible the difference between two instants is, in bar points (0.27 pt per canvas unit): the largest movement of
// any piece. The dot's colour counts a tenth of a point for every 3% of transition.
func visibleDistance(_ a: MascotLook, _ b: MascotLook, _ g: MascotGeometry) -> Double {
    func eye(_ p: EyePose, _ q: EyePose) -> Double {
        max(abs(p.w - q.w), abs(p.h - q.h), abs(p.bend - q.bend) * 1.3, abs(p.lid - q.lid) * max(p.h, q.h))
    }
    func shift(_ p: CGVector, _ q: CGVector) -> Double { max(abs(p.dx - q.dx), abs(p.dy - q.dy)) }
    func opt(_ x: Double?, _ y: Double?, _ k: Double) -> Double {
        switch (x, y) {
        case let (x?, y?): abs(x - y) * k
        case (nil, nil): 0
        default: .infinity   // appears or vanishes: draw
        }
    }
    // ponytail: the face's shift away from the dot (mascotFigure) is not counted; count it if a lag shows at extreme gazes
    let units = max(abs(a.gazeX - b.gazeX) * g.faceX, abs(a.gazeY - b.gazeY) * g.faceY,
                    abs(a.squash - b.squash) * 62, abs(a.tilt - b.tilt) * 42, abs(a.lift - b.lift),
                    eye(a.left, b.left) * g.eyes.size, eye(a.right, b.right) * g.eyes.size, shift(a.leftShift, b.leftShift),
                    shift(a.rightShift, b.rightShift), abs(a.dot - b.dot) * 24, opt(a.z, b.z, 10), opt(a.sparkle, b.sparkle, 8), opt(a.heart, b.heart, 90), opt(a.dizzy, b.dizzy, 120))
    // the spin: the eyes slide on the head's cylinder (radius at most 45: shapes sit between 4 and 96), at most the arc
    let turn = abs(a.turn - b.turn) * 2 * .pi * 45
    return max(max(units, turn) * 0.27, abs(a.dotFade - b.dotFade) * 3)
}

// The redraw rule, the same in the view and in the budget test: redraw when the difference shows, with the step of the
// current rhythm.
public func shouldRedraw(_ drawn: MascotLook, _ life: MascotLife) -> Bool {
    visibleDistance(drawn, life.look, life.geometry) >= (life.fastFrames ? fastStep : visibleStep)
}

private struct EyeSprings {
    var w, h, bend, lid: MascotSpring
    init(_ p: EyePose) {
        w = MascotSpring(p.w, omega: 22); h = MascotSpring(p.h, omega: 50)   // the quick height: it blinks
        bend = MascotSpring(p.bend, omega: 22); lid = MascotSpring(p.lid, omega: 30)
    }
    var pose: EyePose { EyePose(w: w.x, h: h.x, bend: bend.x, lid: lid.x) }
    var still: Bool { w.still(0.1) && h.still(0.1) && bend.still(0.08) && lid.still(0.01) }   // the rest is not visible (~0.03 pt)
    mutating func aim(_ p: EyePose) { w.target = p.w; h.target = p.h; bend.target = p.bend; lid.target = p.lid }
    mutating func step(_ dt: Double) { w.step(dt); h.step(dt); bend.step(dt); lid.step(dt) }
}

// The background amplitudes per state: breath (extra height at the peak), sway (radians), eye drift (canvas units) and
// the length of a breath. About 3–5 times Grok in proportion: at our size theirs would vanish.
// While asleep the drift is 1.0 and not 0.6: it covers the moments when breath and sway are both still (with 0.6 a
// 2-minute run in 12 stayed still for more than 3 s, with 1.0 none in 10,000: the longest 2.8 s).
private struct Background: Equatable {
    var breath, sway, drift: Double
    var period: ClosedRange<Double>
    static let asleep = Background(breath: 0.026, sway: 0.03, drift: 1.0, period: 9...11)
    static let awake = Background(breath: 0.02, sway: 0.045, drift: 0.9, period: 6.4...8.4)
    static let alarmed = Background(breath: 0.015, sway: 0.02, drift: 0.5, period: 2.4...3)
}

// From 0 to 1 starting and ending gently (smoothstep): the breath and the spin.
private func ease(_ k: Double) -> Double { k * k * (3 - 2 * k) }

// A breath from 0 to 1 and back: inhale in the first 40%, exhale in 50%, then a pause.
private func breathShape(_ p: Double) -> Double {
    let p = min(max(p, 0), 1)
    return p < 0.4 ? ease(p / 0.4) : p < 0.9 ? 1 - ease((p - 0.4) / 0.5) : 0
}

// The life: the mood says the activity (sleeps, peeks, reads, calls you, cheers, alarm, looks at you), the activity
// schedules the gestures, the gestures move the springs' targets; on top, the background. When no spring is moving the
// physics skips ahead to the next gesture: the background is made of waves computed from time and needs no steps.
public struct MascotLife {
    static let step = 1.0 / 120
    static let gravity = 620.0   // canvas units per second²: a hop 10 high stays in the air ~0.36 s
    public static let calmFPS = 15.0, fastFPS = 60.0   // the view's two rhythms: the background, the gestures
    static let spinTime = 1.0                   // the spin on itself
    static var spinGap = 25.0...45.0            // how often, while working
    static let pressSquash = 0.8                 // pressed: the body's height
    static let quickTaps = 4, tapGap = 0.5       // 4 clicks, each within half a second of the previous one
    static let heartTime = 1.4, dizzyTime = 1.8  // the little heart and the spiral eyes

    public var geometry: MascotGeometry   // shape and eyes: the view changes it when the settings change
    public private(set) var look = MascotLook()
    private(set) var time = 0.0                  // seconds of life
    private var acc = 0.0
    private var rng: SplitMix
    private var input = MascotInput(mood: .sleep)
    private var lastMood: MascotMood?            // to notice a new "done"
    private var activity = Activity.asleep
    private var peeking = false, peekHalf = false, cheering = false, drowsy = false, lookingUp = false
    private var blinkL = false, blinkR = false   // blink in progress, also of one eye only
    private var wink: Int?                       // the eye of the wink in progress
    private var hopsLeft = 0
    private var readX = -0.45                    // where the reading has got to on the line

    private var gx = MascotSpring(0.1, omega: 18), gy = MascotSpring(0.4, omega: 18)
    private var squash = MascotSpring(1, omega: 28, zeta: 0.4)
    private var tilt = MascotSpring(0, omega: 30, zeta: 0.35)
    private var lift = 0.0, liftV = 0.0
    private var dot = MascotSpring(0, omega: 12, zeta: 0.55), fade = MascotSpring(1, omega: 8)
    private var eyes = [EyeSprings(.asleep), EyeSprings(.asleep)]
    private var zStart: Double?, sparkStart: Double?, spinStart: Double?
    private var wasPressed = false, taps = 0, lastTap = -Double.infinity   // the quick clicks
    private var heartStart: Double?, dizzyStart: Double?
    private var timers = [Double](repeating: .infinity, count: Gesture.allCases.count)   // instant of each gesture

    // The background: random phases for each mascot (two sway waves, three of the eyes' drift), the breath in progress,
    // the amplitudes that pass gently from one state to the other.
    private let phases: [Double]
    private var breathStart = 0.0, breathLen = 10.0, breathGain = 1.0
    private var calm = Background.asleep, calmFrom = Background.asleep, calmSince = -100.0

    private enum Activity { case asleep, peek, read, call, cheer, alarmed, hover }
    private enum Gesture: Int, CaseIterable {
        case wake, nap, nodEnd, peekOpen, cheerEnd, blink, reopen, glance, glanceBack, unwink, saccade, lookUp, lookDown,
             shift, settle, z, hop, kick, tremble, spin, spinEnd, bowEnd
    }

    public init(kind: MascotKind, seed: UInt64) {
        geometry = .of(kind)
        var r = SplitMix(s: seed)
        phases = (0..<5).map { _ in Double.random(in: 0..<(2 * .pi), using: &r) }
        rng = r
        breathLen = .random(in: Background.asleep.period, using: &rng)
        breathStart = -.random(in: 0..<breathLen, using: &rng)   // the first breath starts from a random point: Mostro and Mirtillo do not breathe together
        enter(.asleep, nap: 30)   // the first sleep lasts 30 s, as before
        look = current
    }

    // The springs are moving: a gesture in progress or the hop in flight. The background does not count.
    var moving: Bool {
        lift > 0 || liftV != 0 || spinStart != nil
            || !(gx.still(0.008) && gy.still(0.008) && squash.still(0.002) && tilt.still(0.0025)
                 && dot.still(0.005) && fade.still(0.01) && eyes.allSatisfy(\.still))
    }

    // 60 images a second are needed: a gesture in progress, the sparkles, or a gesture starting before the next slow
    // image. For the background alone 15 are enough.
    public var fastFrames: Bool {
        moving || sparkStart.map { time - $0 < 1.6 } == true || reacting || nextEventIn < 1 / Self.calmFPS
    }

    // Seconds to the next gesture (infinite if none).
    var nextEventIn: Double { (timers.min() ?? .infinity) - time }

    // Advances by `dt` seconds with the current input.
    public mutating func advance(_ dt: Double, input new: MascotInput) {
        input = new
        acc += max(0, dt)
        refresh()
        while acc >= Self.step {
            if !moving {   // springs still: skip to the next gesture (or as far as the time goes) without physics
                let n = min((acc / Self.step).rounded(.down), (nextEventIn / Self.step).rounded(.down))
                if n >= 1 { time += n * Self.step; acc -= n * Self.step; rollBreath(); continue }
            }
            tick()
            acc -= Self.step
        }
        look = current
    }

    // The dot changes colour while it is out: fading starts again.
    public mutating func dotColorChanged() { fade.x = 0; fade.v = 0; look = current }

    // The background amplitudes now, even halfway through a transition (~1.5 s).
    private var calmNow: Background {
        let k = 1 - exp(-(time - calmSince) / 0.5)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return Background(breath: mix(calmFrom.breath, calm.breath), sway: mix(calmFrom.sway, calm.sway),
                          drift: mix(calmFrom.drift, calm.drift), period: calm.period)
    }

    private var current: MascotLook {
        let bg = calmNow, w = 2 * Double.pi * time
        let breath = bg.breath * breathGain * breathShape((time - breathStart) / breathLen)
        let sway = bg.sway * (0.7 * sin(w / 12.6 + phases[0]) + 0.3 * sin(w / 37 + phases[1]))   // Grok's waves
        func drift(_ e: Double) -> CGVector {   // e: 0 one eye, 1 the other, out of phase as in Grok
            CGVector(dx: bg.drift * (0.75 * sin(w / 15 + phases[2] + e) + 0.25 * sin(w / 6.3 + phases[3] + 2 * e)),
                     dy: bg.drift * 0.5 * sin(w / 10.8 + phases[4] + e))
        }
        var look = MascotLook()
        look.gazeX = gx.x; look.gazeY = gy.x; look.squash = squash.x + breath; look.tilt = tilt.x + sway; look.lift = lift
        look.left = eyes[0].pose; look.right = eyes[1].pose; look.leftShift = drift(0); look.rightShift = drift(1)
        look.dot = dot.x; look.dotFade = fade.x
        look.z = zStart.flatMap { time - $0 < 2.4 ? (time - $0) / 2.4 : nil }
        look.sparkle = sparkStart.flatMap { time - $0 < 1.6 ? (time - $0) / 1.6 : nil }
        look.turn = spinStart.map { ease(min(max((time - $0) / Self.spinTime, 0), 1)) } ?? 0
        look.heart = heartStart.flatMap { time - $0 < Self.heartTime ? (time - $0) / Self.heartTime : nil }
        look.dizzy = dizzyStart.flatMap { time - $0 < Self.dizzyTime ? (time - $0) / Self.dizzyTime : nil }
        return look
    }

    // One breath after another, each a little different; asleep, an occasional sigh (about one in five).
    private mutating func rollBreath() {
        while time - breathStart >= breathLen {
            breathStart += breathLen
            let sigh = activity == .asleep && chance(0.2)
            breathLen = .random(in: calm.period, using: &rng) * (sigh ? 1.4 : 1)
            breathGain = sigh ? 1.8 : .random(in: 0.85...1.15, using: &rng)
        }
    }

    private mutating func tick() {
        let h = Self.step
        refresh()
        for g in Gesture.allCases where timers[g.rawValue] <= time + 1e-9 {
            timers[g.rawValue] = .infinity
            fire(g)
        }
        refresh()   // a gesture can change the activity (wake, nap, end of the hops)
        aim()
        gx.step(h); gy.step(h); squash.step(h); tilt.step(h); dot.step(h); fade.step(h)
        for i in eyes.indices { eyes[i].step(h) }
        if lift > 0 || liftV > 0 {   // in flight: gravity brings it down, on landing the body squashes
            liftV -= Self.gravity * h
            lift += liftV * h
            if lift <= 0 { lift = 0; squash.v -= abs(liftV) * 0.008; liftV = 0 }
        }
        time += h
        rollBreath()
    }

    // From the input to the activity. A new "done" cheers for 2.4 s, then sleeps; the pointer over the mascot wins over
    // everything except the cheer.
    private mutating func refresh() {
        if input.pressed != wasPressed {   // pressed or released: released it goes back up (the spring bounces) and the click counts
            wasPressed = input.pressed
            if !input.pressed { squash.target = 1; tapped() }
        }
        if input.mood != lastMood {
            cheering = input.mood == .done
            timers[Gesture.cheerEnd.rawValue] = cheering ? time + 2.4 : .infinity
            lastMood = input.mood
        }
        dot.target = input.dot ? 1 : 0
        let next: Activity
        if let p = input.hover, !cheering {   // looks at you: towards the pointer, within the face's limits
            next = .hover
            gx.target = min(max((p.x - 50) / 30, -1), 1)
            gy.target = min(max((p.y - geometry.eyeY) / 25, -1), 1)
        } else {
            switch input.mood {
            case .sleep: next = peeking ? .peek : .asleep
            case .done: next = cheering ? .cheer : peeking ? .peek : .asleep
            case .work, .watch: next = .read
            case .wait: next = .call
            case .alarm: next = .alarmed
            }
        }
        if next != activity { enter(next) }
        // pressed wins over gestures and activity changes, which put the body back to 1 (hops, nodding, enter)
        if input.pressed { squash.target = Self.pressSquash }
    }

    private mutating func enter(_ a: Activity, nap: Double? = nil) {
        let from = activity
        activity = a
        peeking = a == .peek   // an interrupted peek (work, pointer, "done") does not stay pending
        let sleepy = a == .asleep || a == .peek
        // the resettle (every 40–80 s) stays pending between a sleep and a peek: the wake-ups (every 20–40 s) do not
        // cancel it, every other activity does
        for g in Gesture.allCases where g != .cheerEnd && !(sleepy && g == .settle) { timers[g.rawValue] = .infinity }
        blinkL = false; blinkR = false; wink = nil; drowsy = false; lookingUp = false; spinStart = nil
        squash.target = 1; tilt.target = 0
        let bg: Background = sleepy ? .asleep : a == .alarmed ? .alarmed : .awake
        if bg != calm { calmFrom = calmNow; calm = bg; calmSince = time }
        switch a {
        case .asleep:
            gx.target = 0.1; gy.target = 0.4
            let wait = nap ?? .random(in: 20...40, using: &rng)
            at(.wake, time + wait)
            after(.z, 4...8); after(.shift, 4...8)
            if timers[Gesture.settle.rawValue] == .infinity { after(.settle, 40...80) }   // only one pending
            if from != .asleep {   // falls asleep nodding: the head drops a little and tilts (eyes open: half)
                drowsy = from != .cheer
                squash.target = 0.95
                let s = side(); tilt.v += 0.6 * s
                at(.nodEnd, time + 0.7)
            }
        case .peek:   // opens its eyes slowly, looks around, falls asleep again
            peekHalf = true
            at(.peekOpen, time + 0.35); at(.glance, time + 0.6); at(.nap, time + 2.4)
        case .read:   // a blink at every state change, like Grok: it hides the change of eyes
            readX = -0.45; gx.target = readX; gy.target = 0.35
            at(.blink, time + 0.05); after(.saccade, 1.2...1.8); after(.lookUp, 15...25)
            if input.mood == .work { after(.spin, Self.spinGap) }   // the AI monitor at work, now and then, a spin
        case .call:
            gx.target = 0.1; gy.target = -0.3
            at(.blink, time + 0.05); at(.hop, time + 0.3); after(.glance, 6...12)
        case .cheer:
            gx.target = 0; gy.target = -0.2
            hopsLeft = 2; at(.hop, time + 0.1); sparkStart = time
        case .alarmed:
            gx.target = 0; gy.target = -0.1
            at(.blink, time + 0.05); at(.tremble, time + 0.2)
        case .hover:
            at(.blink, time + 0.05)
        }
    }

    // How often it blinks: less while reading (like people), even less with wide eyes.
    private var blinkEvery: ClosedRange<Double> {
        switch activity {
        case .read: 7...12
        case .alarmed: 6...9
        default: 4...8
        }
    }

    // A released click: counts quick clicks; at the fourth a random reaction, 50/50. During a reaction clicks do not count
    // (when it ends, start again from zero).
    private mutating func tapped() {
        guard !reacting else { taps = 0; return }
        taps = time - lastTap <= Self.tapGap ? taps + 1 : 1
        lastTap = time
        guard taps >= Self.quickTaps else { return }
        taps = 0
        if Bool.random(using: &rng) { heartStart = time } else { dizzyStart = time }
    }

    private var reacting: Bool {
        heartStart.map { time - $0 < Self.heartTime } == true || dizzyStart.map { time - $0 < Self.dizzyTime } == true
    }

    private mutating func fire(_ g: Gesture) {
        switch g {
        case .wake: peeking = true
        case .nap: peeking = false
        case .nodEnd: drowsy = false; squash.target = 1
        case .peekOpen: peekHalf = false
        case .cheerEnd: cheering = false
        case .blink:   // both eyes, occasionally just one (an asymmetry like Grok)
            let one = chance(0.2), right = Bool.random(using: &rng)
            blinkL = !one || !right; blinkR = !one || right
            at(.reopen, time + 0.12)
        case .reopen:
            blinkL = false; blinkR = false
            if chance(0.15) { at(.blink, time + 0.15) } else { after(.blink, blinkEvery) }
        case .glance:
            if activity == .peek {   // peeking: a single glance, then falls asleep again
                glanceAway(0.2...0.5)
            } else if chance(0.1) {   // waiting for you: now and then a wink
                wink = Int.random(in: 0...1, using: &rng); at(.unwink, time + 0.35); after(.glance, 6...12)
            } else {   // looks elsewhere, stays there a while, comes back to you
                glanceAway(0.4...0.7); after(.glanceBack, 1.5...3); after(.glance, 6...12)
            }
        case .glanceBack: gx.target = 0.1; gy.target = -0.3
        case .unwink: wink = nil
        case .saccade:   // reads: a jump to the right; at the end of the line it starts a new one; with eyes raised it waits
            if lookingUp { at(.saccade, time + 0.5) }
            else if readX + 0.35 > 0.5 {   // new line; the AI monitor at work with a little bow forward
                readX = -0.45; gx.target = readX; after(.saccade, 1.4...1.9)
                if input.mood == .work { tilt.target = 0.07; at(.bowEnd, time + 0.3) }
            }
            else {
                let jump = Double.random(in: 0.25...0.35, using: &rng)
                readX += jump; gx.target = readX
                after(.saccade, 1.2...1.8)
            }
        case .lookUp:   // raises its eyes to you, then goes back to reading
            lookingUp = true
            let x = Double.random(in: -0.1...0.3, using: &rng)
            gx.target = x; gy.target = -0.25
            after(.lookDown, 1.5...2.5); after(.lookUp, 15...25)
        case .lookDown: lookingUp = false; gx.target = readX; gy.target = 0.35
        case .shift:   // asleep, the closed eyes shift slightly
            let x = Double.random(in: -0.05...0.25, using: &rng), y = Double.random(in: 0.3...0.5, using: &rng)
            gx.target = x; gy.target = y
            after(.shift, 4...8)
        case .settle:   // resettles: leans a little to one side and stays there
            let lean = Double.random(in: -0.04...0.04, using: &rng)
            tilt.target = lean; squash.v -= 0.3
            after(.settle, 40...80)
        case .z: zStart = time; after(.z, 30...40)
        case .hop: squash.target = 0.92; at(.kick, time + 0.08)   // crouches, then takes off
        case .kick:
            if !input.pressed {   // pressed it stays on the ground
                squash.target = 1; squash.v += 1
                liftV = (2 * Self.gravity * (activity == .cheer ? 10 : 5)).squareRoot()
            }
            if activity == .cheer { hopsLeft -= 1; if hopsLeft > 0 { at(.hop, time + 0.55) } } else { after(.hop, 8...10) }
        case .tremble: let s = side(); tilt.v += 3.5 * s; after(.tremble, 3...5)
        case .bowEnd: tilt.target = 0
        // The spin on itself, like Grok: the eyes go around the head in one second (mascotFigure), at the end a little hop.
        // Only while working: if the mood changes the reading continues (same activity), the spins do not.
        case .spin: if input.mood == .work { spinStart = time; at(.spinEnd, time + Self.spinTime) }
        case .spinEnd:
            spinStart = nil
            if !input.pressed { liftV = (2 * Self.gravity * 3).squareRoot() }   // pressed it stays on the ground
            if input.mood == .work { after(.spin, Self.spinGap) }
        }
    }

    // The eyes towards the activity's shape; wink and blinks on top.
    private mutating func aim() {
        for i in eyes.indices {
            var p: EyePose
            switch activity {
            case .asleep: p = drowsy ? .half : .asleep
            case .peek: p = peekHalf ? .half : .open
            case .read, .call, .hover: p = .open
            case .cheer: p = .happy
            case .alarmed: p = .wide
            }
            if wink == i { p = .wink }
            if (i == 0 ? blinkL : blinkR), p.h > 6 { p.h = 1.25 }   // only open eyes (closed arches are 4.4 tall)
            eyes[i].aim(p)
        }
    }

    private mutating func glanceAway(_ r: ClosedRange<Double>) {
        gx.target = .random(in: r, using: &rng) * side()
        gy.target = .random(in: -0.2...0.3, using: &rng)
    }
    private mutating func at(_ g: Gesture, _ t: Double) { timers[g.rawValue] = t }
    private mutating func after(_ g: Gesture, _ r: ClosedRange<Double>) { timers[g.rawValue] = time + .random(in: r, using: &rng) }
    private mutating func chance(_ p: Double) -> Bool { .random(in: 0..<1, using: &rng) < p }
    private mutating func side() -> Double { Bool.random(using: &rng) ? 1 : -1 }
}
