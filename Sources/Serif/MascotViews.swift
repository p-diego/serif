import AppKit
import SwiftUI
import SerifCore

/// The living mascot, drawn by the view itself in draw(_:) like an image that changes (never CAAnimation: it keeps the
/// compositor at 120 Hz). A displayLink runs while the mascot is visible: 15 frames per second in the background, 60
/// during gestures (`fastFrames`), 1 when nobody can see it; it only redraws when `shouldRedraw` says so.
struct LiveMascot: NSViewRepresentable {
    let face: BotFace
    let mood: MascotMood
    let avatar: CGFloat    // the body fills this square; the view is `liveInset` bigger on every side for hops and sparkles
    var running = true

    static let inset: CGFloat = 8

    func makeNSView(context: Context) -> MascotNSView { MascotNSView(geometry: MascotGeometry.of(face), avatar: avatar, inset: Self.inset) }

    func updateNSView(_ view: MascotNSView, context: Context) {
        let geometry = MascotGeometry.of(face)
        if view.geometry != geometry { view.geometry = geometry }
        view.avatar = avatar
        view.update(colors: MascotColors(body: cgColor(hex: face.body), eyes: cgColor(hex: face.eyes), dot: nil),
                    mood: mood, running: running)
    }

    static func dismantleNSView(_ view: MascotNSView, coordinator: ()) { view.stop() }
}

final class MascotNSView: NSView {
    private var life: MascotLife
    private var input = MascotInput(mood: .sleep)
    private(set) var drawn: MascotLook    // the last real drawing
    private var colors = MascotColors(body: cgColor(hex: 0xF5F7FC), eyes: cgColor(hex: 0x14141A), dot: nil)
    private var running = true
    private var link: CADisplayLink?
    private var clock = CACurrentMediaTime()

    var geometry: MascotGeometry {    // shape and eyes: redraw, the life goes on
        get { life.geometry }
        set { life.geometry = newValue; needsDisplay = true }
    }

    var avatar: CGFloat { didSet { if avatar != oldValue { needsDisplay = true } } }
    private let inset: CGFloat
    private var layout: (size: CGSize, offset: CGPoint) { avatarLayout(life.geometry, avatar: avatar, inset: inset) }

    init(geometry: MascotGeometry, avatar: CGFloat, inset: CGFloat) {
        self.avatar = avatar
        self.inset = inset
        life = MascotLife(kind: geometry.shape, seed: .random(in: 0...UInt64.max))    // each with its own rhythm: never blinking together
        life.geometry = geometry
        drawn = life.look
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }    // y down, like the canvas

    func update(colors new: MascotColors, mood: MascotMood, running r: Bool) {
        let next = MascotInput(mood: mood, dot: false, hover: input.hover, pressed: input.pressed)
        let changed = next != input || r != running
        // The time spent standing still is played with the previous input.
        if changed { advance() }
        if new.body != colors.body || new.eyes != colors.eyes { needsDisplay = true }
        colors = new
        input = next; running = r
        if changed { resume() }
    }

    func stop() { link?.invalidate(); link = nil }

    // Starts again (or pauses when stopped or out of the window): the life catches up and the displayLink runs at the right pace.
    private func resume() {
        guard running, window != nil else { link?.isPaused = true; return }
        advance()
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)    // .common: also advances with a menu open
            link = l
        }
        link?.isPaused = false
        pace()
    }

    @objc private func tick(_ link: CADisplayLink) { advance(); pace() }

    private var invisible: Bool { window.map { $0.alphaValue == 0 || !$0.occlusionState.contains(.visible) } ?? true }

    private func pace() {
        let fps = Float(invisible ? 1 : life.fastFrames ? MascotLife.fastFPS : MascotLife.calmFPS)
        if link?.preferredFrameRateRange.preferred != fps {
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        }
    }

    private func advance() {
        let now = CACurrentMediaTime()
        life.advance(min(now - clock, 60), input: input)    // at most a minute at a time (after the Mac slept)
        clock = now
        if !invisible, shouldRedraw(drawn, life) { drawn = life.look; needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if window == nil { input.pressed = false; stop(); return }
        clock = CACurrentMediaTime(); resume()
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }
    @objc private func occlusionChanged() { resume() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let l = layout
        ctx.translateBy(x: l.offset.x, y: l.offset.y)
        drawMascot(life.geometry, drawn, colors, in: ctx, size: l.size, mirrored: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { advance(); input.hover = nil; resume() }
    private func hover(_ event: NSEvent) {
        advance()
        let l = layout, p = convert(event.locationInWindow, from: nil)
        input.hover = canvasPoint(CGPoint(x: p.x - l.offset.x, y: p.y - l.offset.y), size: l.size, mirrored: false)
        resume()
    }

    // Pressed with the left button: it squashes; released it bounces. The click goes on to SwiftUI.
    override func mouseDown(with event: NSEvent) { press(true); super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { press(false); super.mouseUp(with: event) }
    private func press(_ on: Bool) {
        guard input.pressed != on else { return }
        advance(); input.pressed = on; resume()
    }
}

/// One still frame of a mascot (cached): what every row that is neither working nor waiting shows.
struct MascotImage: View {
    let face: BotFace
    let mood: MascotMood
    let size: CGFloat

    var body: some View {
        Image(nsImage: MascotImageCache.image(face: face, mood: mood, size: size)).resizable().frame(width: size, height: size)
    }
}

@MainActor
enum MascotImageCache {
    private struct Key: Hashable { let face: BotFace; let mood: MascotMood; let size: CGFloat }
    private static var cache: [Key: NSImage] = [:]

    static func image(face: BotFace, mood: MascotMood, size: CGFloat) -> NSImage {
        let key = Key(face: face, mood: mood, size: size)
        if let hit = cache[key] { return hit }
        // The look of a fresh life settled into the mood (a few seconds, so the eyes take their pose).
        var life = MascotLife(kind: face.shape, seed: 1)
        life.geometry = MascotGeometry.of(face)
        let input = MascotInput(mood: mood)
        for _ in 0..<30 { life.advance(0.1, input: input) }
        let colors = MascotColors(body: cgColor(hex: face.body), eyes: cgColor(hex: face.eyes), dot: nil)
        // The body fills the square except a 1 pt margin for its border.
        let layout = avatarLayout(life.geometry, avatar: size - 2, inset: 1)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: layout.offset.x, y: layout.offset.y)
            drawMascot(life.geometry, life.look, colors, in: ctx, size: layout.size, mirrored: false)
            return true
        }
        cache[key] = image
        return image
    }
}
