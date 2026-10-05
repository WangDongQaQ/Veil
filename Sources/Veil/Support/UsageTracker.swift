import Foundation

/// Counts the seconds of audio sent to a billed cloud ASR, per calendar day.
/// Doubao bills by audio duration, so this is the number that matters for cost.
final class UsageTracker: @unchecked Sendable {
    static let shared = UsageTracker()

    /// Pay-as-you-go price of Doubao streaming ASR 2.0 (¥ per hour of audio). Estimate only —
    /// the Volcengine invoice is authoritative; prepaid packs are cheaper.
    static let yuanPerHour = 1.0

    private let lock = NSLock()
    private let defaults = AppDefaults.store

    private var key: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "doubao.usage.seconds." + f.string(from: Date())
    }

    func add(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(defaults.double(forKey: key) + seconds, forKey: key)
    }

    var todaySeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return defaults.double(forKey: key)
    }

    var todayCostYuan: Double { todaySeconds / 3600 * Self.yuanPerHour }

    /// `limitMinutes == 0` means no limit.
    func isOverLimit(minutes limitMinutes: Int) -> Bool {
        limitMinutes > 0 && todaySeconds >= Double(limitMinutes) * 60
    }

    static func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600) 小时 \(total % 3600 / 60) 分" }
        if total >= 60 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total) 秒"
    }
}
