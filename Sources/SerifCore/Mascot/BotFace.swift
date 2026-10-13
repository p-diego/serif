import Foundation

/// A bot's profile picture: one of the mascot shapes plus its colours and eye settings.
public struct BotFace: Codable, Equatable, Hashable, Sendable {
    public var shape: MascotKind
    public var body: Int      // 0xRRGGBB
    public var eyes: Int      // 0xRRGGBB
    public var eyeSize: Double = 1.0
    public var eyeLift: Double = 0.0
    public var eyeSpread: Double = 1.0

    public init(shape: MascotKind, body: Int, eyes: Int, eyeSize: Double = 1, eyeLift: Double = 0, eyeSpread: Double = 1) {
        self.shape = shape
        self.body = body
        self.eyes = eyes
        self.eyeSize = eyeSize
        self.eyeLift = eyeLift
        self.eyeSpread = eyeSpread
    }
}
