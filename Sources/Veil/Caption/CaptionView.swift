import SwiftUI

/// The whole desktop widget: transcript text hidden behind spoiler dust that dissolves
/// from the cursor when you hover it.
struct CaptionView: View {
    @ObservedObject var store: CaptionStore
    @ObservedObject var settings: AppSettings
    var onFinishEditing: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Frame of the text itself (not the whole window) in widget coordinates.
    @State private var textFrame: CGRect = .zero
    @State private var revealed = false
    @State private var fullyRevealed = false
    @State private var revealOrigin: CGPoint = .zero      // widget coordinates
    @State private var revealRadius: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    private static let placeholder = "这里会显示实时字幕。把光标移到文字上，遮罩就会散开。"

    var body: some View {
        let p = settings.p
        ZStack {
            captionLayer(p)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: Alignment(horizontal: p.textAlign.horizontal,
                                            vertical: p.textAnchor == .bottom ? .bottom : .top))
                .padding(10)

            if store.editMode {
                EditOverlay(onDone: onFinishEditing)
            }
        }
        .coordinateSpace(name: "widget")
        .opacity(p.overallOpacity)
        .animation(.easeOut(duration: 0.2), value: store.editMode)
        .onChange(of: store.pointer) { _, _ in updateHover() }
        .onChange(of: textFrame) { _, _ in
            updateHover()
            if revealed, settings.p.revealMode == .block { revealRadius = fullRadius() }
        }
        .onChange(of: store.hasContent) { _, has in if !has && !store.editMode { resetReveal() } }
        .onChange(of: store.editMode) { _, editing in if !editing && !store.hasContent { resetReveal() } }
        .onChange(of: p.spoilerEnabled) { _, _ in resetReveal() }
        .onChange(of: p.revealMode) { _, _ in resetReveal() }
    }

    // MARK: Layers

    @ViewBuilder
    private func captionLayer(_ p: Preferences) -> some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !store.hasContent)) { timeline in
            let runs = displayRuns(now: timeline.date)
            if !runs.isEmpty {
                textBlock(runs: runs, p)
                    .padding(.horizontal, p.background == .none ? 0 : 16)
                    .padding(.vertical, p.background == .none ? 0 : 11)
                    .background { backgroundShape(p) }
                    .transition(.opacity)
            }
        }
    }

    private func displayRuns(now: Date) -> [CaptionStore.Run] {
        let runs = store.runs(now: now)
        if runs.isEmpty && store.editMode { return [.init(id: 0, text: Self.placeholder, alpha: 1)] }
        return runs
    }

    @ViewBuilder
    private func textBlock(runs: [CaptionStore.Run], _ p: Preferences) -> some View {
        let plain = runs.map(\.text).joined()
        let palette = p.palette
        let real = styledText(runs, p, color: palette.text)
            .modifier(TextHalo(color: palette.halo, enabled: p.textShadow, strong: palette.strongOutline))
        let origin = localOrigin()

        Group {
            if p.spoilerEnabled {
                real
                    .mask { revealCircle(origin: origin) }
                    .overlay {
                        DustField(color: palette.dust, halo: palette.dustHalo, wash: palette.dustWash,
                                  density: p.dustDensity, speed: p.dustSpeed, intensity: p.dustIntensity,
                                  paused: reduceMotion || (fullyRevealed && p.revealMode == .block))
                            .mask {
                                ZStack {
                                    softenedGlyphs(runs, p)
                                    revealCircle(origin: origin).blendMode(.destinationOut)
                                }
                                .compositingGroup()
                            }
                            .opacity(fullyRevealed && p.revealMode == .block ? 0 : 1)
                    }
            } else {
                real
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.frame(in: .named("widget")), initial: true) { _, frame in
                        textFrame = frame
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时字幕")
        .accessibilityValue(plain)
    }

    /// Glyph shapes smeared a little, so the hidden text can't be read from the dust's silhouette.
    private func softenedGlyphs(_ runs: [CaptionStore.Run], _ p: Preferences) -> some View {
        let radius = max(2.5, p.fontSize * 0.09)
        let glyphs = styledText(runs, p, color: .white)
        return ZStack {
            glyphs.blur(radius: radius)
            glyphs.blur(radius: radius * 0.5)
            glyphs
        }
    }

    private func styledText(_ runs: [CaptionStore.Run], _ p: Preferences, color: Color) -> some View {
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

    @ViewBuilder
    private func backgroundShape(_ p: Preferences) -> some View {
        switch p.background {
        case .none:
            EmptyView()
        case .dim:
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.42))
        case .glass:
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// Soft-edged disc, in the text's local coordinates, that marks where the veil is lifted.
    private func revealCircle(origin: CGPoint) -> some View {
        Color.clear.overlay(alignment: .topLeading) {
            if revealRadius > 0.5 {
                Circle()
                    .fill(Color.black)
                    .frame(width: revealRadius * 2, height: revealRadius * 2)
                    .blur(radius: min(18, revealRadius * 0.35))
                    .offset(x: origin.x - revealRadius, y: origin.y - revealRadius)
            }
        }
    }

    // MARK: Hover logic

    private func localOrigin() -> CGPoint {
        CGPoint(x: revealOrigin.x - textFrame.minX, y: revealOrigin.y - textFrame.minY)
    }

    private func updateHover() {
        let p = settings.p
        guard p.spoilerEnabled else { return }

        var over = false
        if let pointer = store.pointer, textFrame.width > 0, store.hasContent || store.editMode {
            over = textFrame.insetBy(dx: -16, dy: -12).contains(pointer)
        }

        if over, let pointer = store.pointer {
            hideTask?.cancel()
            hideTask = nil
            if p.revealMode == .spotlight { revealOrigin = pointer }
            if !revealed {
                revealed = true
                revealOrigin = pointer
                expand(p)
            }
        } else if revealed, hideTask == nil {
            let delay = p.hideDelay
            hideTask = Task { @MainActor in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                collapse()
            }
        }
    }

    private func expand(_ p: Preferences) {
        let target = p.revealMode == .block ? fullRadius() : CGFloat(p.spotlightRadius)
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.1)
            : .smooth(duration: p.revealMode == .block ? 0.7 : 0.35)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            revealRadius = target
        } completion: {
            if revealed && settings.p.revealMode == .block { fullyRevealed = true }
        }
    }

    private func collapse() {
        hideTask = nil
        revealed = false
        fullyRevealed = false
        withAnimation(reduceMotion ? .easeIn(duration: 0.1) : .smooth(duration: 0.5)) { revealRadius = 0 }
    }

    private func resetReveal() {
        hideTask?.cancel()
        hideTask = nil
        revealed = false
        fullyRevealed = false
        revealRadius = 0
    }

    /// Radius that reaches the farthest corner of the text from the reveal origin.
    private func fullRadius() -> CGFloat {
        let corners = [
            CGPoint(x: textFrame.minX, y: textFrame.minY), CGPoint(x: textFrame.maxX, y: textFrame.minY),
            CGPoint(x: textFrame.minX, y: textFrame.maxY), CGPoint(x: textFrame.maxX, y: textFrame.maxY),
        ]
        let farthest = corners.map { hypot($0.x - revealOrigin.x, $0.y - revealOrigin.y) }.max() ?? 0
        return farthest + 28
    }
}


/// Opposite-tone outline / shadow around the glyphs.
private struct TextHalo: ViewModifier {
    var color: Color
    var enabled: Bool
    var strong: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if strong {
            content
                .shadow(color: color.opacity(0.95), radius: 0.7, x: 0, y: 0)
                .shadow(color: color.opacity(0.85), radius: 1.5, x: 0, y: 0.5)
                .shadow(color: color.opacity(0.45), radius: 4, x: 0, y: 1.5)
        } else {
            content.shadow(color: color.opacity(0.6), radius: 3, x: 0, y: 1)
        }
    }
}
