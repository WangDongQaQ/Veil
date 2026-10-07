import SwiftUI

/// Calm spoiler dust: two tiled layers of fine specks that drift slowly in nearly the same direction,
/// like haze. Opacity is constant — nothing twinkles or fades in and out, so it never pulls the eye.
/// Meant to be masked by the (softened) glyph shapes of the hidden text.
struct DustField: View {
    var color: Color
    /// Opposite-tone twin drawn just behind every speck, so the dust reads on light and dark backdrops alike.
    var halo: Color
    /// Faint constant washes under the specks: dark (shows on light backdrops) and light (shows on dark ones).
    var wash: Color
    var lightWash: Color
    var density: Double      // 0…1
    var speed: Double        // 0…1
    /// 0…1: overall strength of specks, halo and wash. Low = just a hint that something is there.
    var intensity: Double
    var paused: Bool

    var body: some View {
        let tiles = DustTiles.images(for: density)
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: paused)) { timeline in
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                Self.draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate,
                          tiles: tiles, color: color, halo: halo, wash: wash, lightWash: lightWash, speed: speed, intensity: intensity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private static let tilePoints: CGFloat = 128

    private struct Layer {
        var velocity: CGVector     // points per second at motion = 1
        var opacity: Double        // constant
        var sway: CGFloat          // amplitude of the slow side-to-side breathing, in points
        var swayPeriod: Double
    }

    // Same general direction, slightly different speeds: gentle parallax instead of shimmer.
    private static let layers: [Layer] = [
        Layer(velocity: CGVector(dx: 7, dy: -4), opacity: 0.62, sway: 3.0, swayPeriod: 9),
        Layer(velocity: CGVector(dx: 4.5, dy: -6), opacity: 0.42, sway: 2.2, swayPeriod: 13),
    ]

    private static func draw(_ context: inout GraphicsContext, size: CGSize, time t: Double,
                             tiles: [CGImage], color: Color, halo: Color, wash: Color, lightWash: Color, speed: Double, intensity: Double) {
        guard size.width > 1, size.height > 1 else { return }
        let motion = 0.2 + speed * 1.2
        // The slider's lowest position is still a clearly visible veil (it used to fade to nothing).
        let k = 0.22 + 0.78 * min(1, max(0, intensity))

        // Faint, constant washes: give the glyph silhouettes a body on light and on dark backdrops alike.
        let whole = Path(CGRect(origin: .zero, size: size))
        context.fill(whole, with: .color(wash.opacity(0.20 * k)))
        context.fill(whole, with: .color(lightWash.opacity(0.11 * k)))

        for (index, layer) in layers.enumerated() {
            var image = context.resolve(Image(decorative: tiles[index % tiles.count], scale: 2).renderingMode(.template))
            var shadow = image
            image.shading = .color(color)
            shadow.shading = .color(halo)

            let sway = layer.sway * sin(t * 2 * .pi / layer.swayPeriod)
            let dx = (t * layer.velocity.dx * motion + sway).truncatingRemainder(dividingBy: tilePoints)
            let dy = (t * layer.velocity.dy * motion - sway * 0.6).truncatingRemainder(dividingBy: tilePoints)
            // Halo first (nudged down-right), then the speck itself: an embossed grain.
            for (resolved, nudge, opacity) in [(shadow, CGPoint(x: 0.9, y: 1.1), min(1, layer.opacity * 1.35) * k),
                                                (image, CGPoint.zero, layer.opacity * k)] {
                context.opacity = opacity
                var y = -tilePoints + dy + nudge.y
                while y < size.height {
                    var x = -tilePoints + dx + nudge.x
                    while x < size.width {
                        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
                        x += tilePoints
                    }
                    y += tilePoints
                }
            }
        }
        context.opacity = 1
    }
}

// MARK: - Tiles

/// Pre-rendered noise tiles (256 px = 128 pt @2x). Built once per density step and cached.
private enum DustTiles {
    private static var cache: [Int: [CGImage]] = [:]
    private static let lock = NSLock()

    static func images(for density: Double) -> [CGImage] {
        let step = Int((min(max(density, 0), 1) * 10).rounded())
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[step] { return cached }
        let fraction = 0.11 + Double(step) / 10 * 0.17         // share of pixels that carry a speck
        let tiles = (0..<3).map { make(fraction: fraction, seed: UInt64($0 + 1) &* 7919) }
        cache[step] = tiles
        return tiles
    }

    private static func make(fraction: Double, seed: UInt64) -> CGImage {
        let side = 256
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var g = SplitMix(seed: seed)
        let specks = Int(Double(side * side) * fraction / 3.2)
        for _ in 0..<specks {
            let w = 1 + Int(g.unit() * 1.9)                    // 1–2 px wide
            let h = 1 + Int(g.unit() * 1.9)
            let alpha = 0.55 + g.unit() * 0.35
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            let x = Int(g.unit() * Double(side)), y = Int(g.unit() * Double(side))
            // Wrap around the edges so the tile is seamless.
            for ox in [0, -side] { for oy in [0, -side] {
                ctx.fill(CGRect(x: x + ox, y: y + oy, width: w, height: h))
            } }
        }
        return ctx.makeImage()!
    }
}

/// Small deterministic generator so every speck's life is a pure function of (index, time).
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
