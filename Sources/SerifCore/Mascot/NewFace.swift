import CoreGraphics
import Foundation

/// The ready-made body colours.
public let mascotSwatches = [0xF5F7FC, 0x14141A, 0xE8483F, 0xF08A24, 0xF0B429, 0x3ECF8E, 0x2FBFA0, 0x739EFA, 0x8B5CF6, 0xE152B0, 0xA3A3A3, 0xF1EFE9]

/// Minimum contrast between eyes and body of a new face: 3:1, the WCAG 1.4.11 threshold for graphics (at 4.5:1, the text
/// threshold, they were almost always born with black eyes and never purple).
let mascotEyeContrast = 3.0

// WCAG contrast between two 0xRRGGBB colours, from 1 to 21 (same maths as Siigil's `contrast` on SwiftUI colours).
private func contrast(_ a: Int, _ b: Int) -> Double {
    func luminance(_ v: Int) -> Double {
        func lin(_ c: Int) -> Double { let s = Double(c) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin((v >> 16) & 0xFF) + 0.7152 * lin((v >> 8) & 0xFF) + 0.0722 * lin(v & 0xFF)
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// A new face: random shape; random body among the 12 ready-made colours; random eyes among the ready-made colours that
/// read well on the body (`mascotEyeContrast`); a body colour no existing face uses is preferred while any remain; if shape + body + eyes already exist, draw again. With a fixed generator
/// it is repeatable.
public func randomFace<R: RandomNumberGenerator>(existing: [BotFace], using rng: inout R) -> BotFace {
    let readable = Dictionary(uniqueKeysWithValues: mascotSwatches.map { body in
        (body, mascotSwatches.filter { contrast($0, body) >= mascotEyeContrast })
    })
    func taken(_ s: MascotKind, _ b: Int, _ e: Int) -> Bool { existing.contains { $0.shape == s && $0.body == b && $0.eyes == e } }
    // Every combination is taken (34 body-eyes pairs per shape): a duplicate is better than not being born.
    let full = MascotKind.allCases.allSatisfy { s in mascotSwatches.allSatisfy { b in readable[b]!.allSatisfy { taken(s, b, $0) } } }
    // Prefer a body colour no existing face uses while some remain; then fall back to the distinct-combination rule.
    let unused = mascotSwatches.filter { b in !existing.contains { $0.body == b } }
    var shape: MascotKind, body: Int, eye: Int
    repeat {
        shape = MascotKind.allCases.randomElement(using: &rng)!
        body = (unused.isEmpty ? mascotSwatches : unused).randomElement(using: &rng)!
        eye = readable[body]!.randomElement(using: &rng)!   // at 3:1 every body has at least one eye colour
    } while !full && taken(shape, body, eye)
    return BotFace(shape: shape, body: body, eyes: eye)
}

public func randomFace(existing: [BotFace]) -> BotFace {
    var rng = SystemRandomNumberGenerator()
    return randomFace(existing: existing, using: &rng)
}

extension MascotGeometry {
    public static func of(_ face: BotFace) -> MascotGeometry { of(face.shape, EyeSettings(face)) }
}
