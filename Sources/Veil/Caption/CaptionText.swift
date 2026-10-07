import SwiftUI

/// How caption text is drawn. Shared by the desktop widget and the live previews in Settings, so what
/// the previews show is exactly what the widget renders.
/// Geometry of the `.crisp` outline. Production always uses `.standard`; the style lab compares variants.
struct OutlineTuning {
    var widthPerPoint: Double      // outline width as a share of the font size
    var minWidth: Double
    var maxWidth: Double
    var alpha: Double              // outline opacity
    var shadowAlpha: Double        // soft depth shadow under it
    var shadowRadius: Double
    var shadowY: Double

    /// Chosen from the style lab (VEIL_STYLE_LAB): a thin edge and a very light shadow read clearly on white,
    /// light grey, wallpapers and dark alike, without the heavy "sticker" look of a thick outline or big glow.
    /// The user's "描边粗细" slider (0…1, 0.5 = standard): thinner/lighter to the left, bolder to the right.
    func scaled(strength: Double) -> OutlineTuning {
        let s = min(1, max(0, strength))
        let width = 0.55 + 0.90 * s
        let edge = 0.80 + 0.40 * s
        let shadow = 0.50 + 1.00 * s
        return OutlineTuning(widthPerPoint: widthPerPoint * width, minWidth: minWidth * width, maxWidth: maxWidth * width,
                             alpha: min(0.96, alpha * edge), shadowAlpha: shadowAlpha * shadow,
                             shadowRadius: shadowRadius, shadowY: shadowY)
    }

    static let standard = OutlineTuning(widthPerPoint: 0.032, minWidth: 0.7, maxWidth: 1.3, alpha: 0.78,
                                        shadowAlpha: 0.16, shadowRadius: 3, shadowY: 1)
}

@MainActor
enum CaptionText {
    /// The text laid out with the user's font and alignment, in one color. Old lines carry their own fade alpha.
    static func styled(_ runs: [CaptionStore.Run], _ p: Preferences, color: Color) -> some View {
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece.foregroundColor = color.opacity(run.alpha)
            attributed += piece
        }
        return Text(attributed)
            .font(.system(size: p.fontSize, weight: p.fontWeight.weight, design: p.fontDesign.design))
            .multilineTextAlignment(p.textAlign.alignment)
            .lineSpacing(p.fontSize * 0.14)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The readable text: the fill color plus the chosen edge treatment.
    ///
    /// `.crisp` draws a real thin outline — copies of the text in the outline color placed on a small ring
    /// underneath the fill — plus a faint soft shadow for depth. (A blurred halo, which this used to be,
    /// reads as a smudge on white instead of an edge.)
    @ViewBuilder
    static func outlined(_ runs: [CaptionStore.Run], _ p: Preferences, tuning: OutlineTuning? = nil) -> some View {
        let palette = p.palette
        let fill = styled(runs, p, color: palette.text)
        switch palette.outlineStyle {
        case .none:
            fill
        case .soft:
            fill.shadow(color: palette.outline.opacity(0.6), radius: 3, x: 0, y: 1)
        case .crisp:
            let tuning = tuning ?? OutlineTuning.standard.scaled(strength: p.outlineStrength)
            let width = max(tuning.minWidth, min(tuning.maxWidth, p.fontSize * tuning.widthPerPoint))
            ZStack {
                ForEach(0..<12, id: \.self) { step in
                    let angle = Double(step) / 12 * 2 * .pi
                    styled(runs, p, color: palette.outline.opacity(tuning.alpha))
                        .offset(x: cos(angle) * width, y: sin(angle) * width)
                }
                fill
            }
            .shadow(color: palette.outline.opacity(tuning.shadowAlpha), radius: tuning.shadowRadius, x: 0, y: tuning.shadowY)
        }
    }

    /// Glyph shapes smeared a little, so hidden text can't be read from the dust's silhouette.
    static func softenedGlyphs(_ runs: [CaptionStore.Run], _ p: Preferences) -> some View {
        let radius = max(2.5, p.fontSize * 0.09)
        let glyphs = styled(runs, p, color: .white)
        return ZStack {
            glyphs.blur(radius: radius)
            glyphs.blur(radius: radius * 0.5)
            glyphs
        }
    }
}
