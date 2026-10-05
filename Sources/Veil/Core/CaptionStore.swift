import SwiftUI
import Combine

/// What an ASR engine reports back. Engines only know about "partial text for the utterance
/// that is in progress" and "this utterance is done".
struct TranscriptEvent: Sendable {
    enum Kind: Sendable { case partial, final }
    var kind: Kind
    var text: String
    /// Monotonic id of the utterance this text belongs to. Lets a late `final` for utterance N
    /// avoid wiping the partial text of utterance N+1.
    var utterance: Int = 0
}

/// Holds everything the caption widget draws, plus where the pointer currently is.
@MainActor
final class CaptionStore: ObservableObject {
    struct Segment: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var date: Date
    }

    struct Run: Identifiable {
        let id: Int
        var text: String
        var alpha: Double
    }

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var partial: String = ""
    @Published private(set) var partialDate: Date = .distantPast
    private var partialUtterance = -1

    /// Pointer position in widget coordinates (origin top-left), nil when outside the widget.
    @Published var pointer: CGPoint?
    @Published var editMode = false
    /// True while the pointer is over text that overflows the widget and can be scrolled: the panel then
    /// stops being click-through so the scroll wheel reaches it.
    @Published var wantsMouse = false

    /// Retention rules are injected by the model whenever settings change.
    var retention: TimeInterval = 14
    var maxCharacters = 240

    private var pruneTimer: Timer?
    static let fadeDuration: TimeInterval = 2.6

    var hasContent: Bool { !segments.isEmpty || !partial.isEmpty }

    // MARK: Updating

    func apply(_ event: TranscriptEvent, now: Date = .now) {
        let text = Self.tidy(event.text)
        switch event.kind {
        case .partial:
            partial = text
            partialDate = now
            partialUtterance = event.utterance
        case .final:
            if !text.isEmpty { segments.append(Segment(text: text, date: now)) }
            if partialUtterance <= event.utterance {
                partial = ""
                partialUtterance = -1
            }
        }
        trimToLimit()
        schedulePruneIfNeeded()
    }

    func clear() {
        segments.removeAll()
        partial = ""
        partialUtterance = -1
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    private func trimToLimit() {
        guard maxCharacters > 0 else { return }
        var total = segments.reduce(0) { $0 + $1.text.count } + partial.count
        while total > maxCharacters, segments.count > 0 {
            total -= segments.removeFirst().text.count
        }
    }

    // MARK: Pruning

    func prune(now: Date = .now) {
        if retention > 0 {
            segments.removeAll { $0.date.addingTimeInterval(retention) <= now }
            if !partial.isEmpty, partialDate.addingTimeInterval(retention) <= now {
                partial = ""
                partialUtterance = -1
            }
        }
        if !hasContent {
            pruneTimer?.invalidate()
            pruneTimer = nil
        }
    }

    private func schedulePruneIfNeeded() {
        guard retention > 0, hasContent, pruneTimer == nil else { return }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    func retentionChanged() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        schedulePruneIfNeeded()
    }

    // MARK: Text cleanup

    /// Recognizers often put spaces between Chinese/Japanese tokens ("你好 ，下午"). Drop the ones that
    /// sit between CJK characters or next to CJK punctuation; spaces around Latin words stay.
    static func tidy(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(text)
        guard chars.contains(where: { isCJK($0) || isCJKPunctuation($0) }) else { return text }

        var result = ""
        for (i, ch) in chars.enumerated() {
            if ch.isWhitespace, i > 0, i + 1 < chars.count {
                let prev = chars[i - 1], next = chars[i + 1]
                let touchesPunctuation = isCJKPunctuation(prev) || isCJKPunctuation(next)
                let betweenCJK = (isCJK(prev) || isCJKPunctuation(prev)) && (isCJK(next) || isCJKPunctuation(next))
                if touchesPunctuation || betweenCJK { continue }
            }
            result.append(ch)
        }
        return result
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
            || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    private static func isCJKPunctuation(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    // MARK: Rendering

    /// Text split into runs with their own opacity so old lines can dissolve before they are removed.
    func runs(now: Date) -> [Run] {
        var result: [Run] = []
        var previous: (text: String, date: Date)?

        func alpha(for date: Date) -> Double {
            guard retention > 0 else { return 1 }
            let remaining = date.addingTimeInterval(retention).timeIntervalSince(now)
            return min(1, max(0, remaining / Self.fadeDuration))
        }

        func append(_ text: String, date: Date, alpha: Double) {
            guard !text.isEmpty else { return }
            let separator = previous.map { Self.separator(after: $0.text, before: text, gap: date.timeIntervalSince($0.date)) } ?? ""
            result.append(Run(id: result.count, text: separator + text, alpha: alpha))
            previous = (text, date)
        }

        for s in segments { append(s.text, date: s.date, alpha: alpha(for: s.date)) }
        append(partial, date: partialDate, alpha: 1)
        return result
    }

    private static func separator(after prev: String, before next: String, gap: TimeInterval) -> String {
        if gap > 3.5 { return "\n" }
        guard let a = prev.last, let b = next.first else { return "" }
        let needsSpace = a.isASCII && b.isASCII && !a.isWhitespace && !b.isWhitespace
        return needsSpace ? " " : ""
    }
}
