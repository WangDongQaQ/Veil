// Renders the app icon: three lines of "text" dissolved into dust, with a circular
// patch where the veil has been lifted and the text is crisp.
import AppKit

struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    // Body (Apple's macOS icon grid: 824pt squircle centred in 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    let colors = [NSColor(red: 0.50, green: 0.42, blue: 0.97, alpha: 1).cgColor,
                  NSColor(red: 0.20, green: 0.13, blue: 0.52, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 800, y: 100), options: [])

    // Text lines (bars) — y is bottom-up here.
    let bars: [(x: CGFloat, y: CGFloat, w: CGFloat)] = [
        (210, 640, 520), (210, 470, 600), (210, 300, 380),
    ]
    let barHeight: CGFloat = 92
    let reveal = CGPoint(x: 560, y: 516)
    let revealRadius: CGFloat = 170
    var rng = RNG(state: 7)

    for bar in bars {
        let rect = CGRect(x: bar.x, y: bar.y, width: bar.w, height: barHeight)
        let shape = CGPath(roundedRect: rect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
        let count = Int(rect.width * rect.height / 14)
        for _ in 0..<count {
            let p = CGPoint(x: .random(in: rect.minX...rect.maxX, using: &rng),
                            y: .random(in: rect.minY...rect.maxY, using: &rng))
            guard shape.contains(p) else { continue }
            let dist = hypot(p.x - reveal.x, p.y - reveal.y)
            if dist < revealRadius + 6 { continue }
            let r = CGFloat.random(in: 2.2...5.2, using: &rng)
            let a = CGFloat.random(in: 0.25...0.95, using: &rng)
            ctx.setFillColor(NSColor.white.withAlphaComponent(a).cgColor)
            ctx.fill(CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r))
        }
    }

    // Lifted patch: crisp bars inside a soft circle.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: reveal.x - revealRadius, y: reveal.y - revealRadius,
                              width: revealRadius * 2, height: revealRadius * 2))
    ctx.clip()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    for bar in bars {
        let rect = CGRect(x: bar.x, y: bar.y, width: bar.w, height: barHeight)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(5)
    ctx.strokeEllipse(in: CGRect(x: reveal.x - revealRadius, y: reveal.y - revealRadius,
                                 width: revealRadius * 2, height: revealRadius * 2))

    // Top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = render(size: px)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
