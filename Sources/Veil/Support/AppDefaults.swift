import Foundation

/// The UserDefaults Veil reads and writes. The developer snapshot / feed tools run against a throw-away
/// suite so they can never touch the real user's settings or usage counters.
enum AppDefaults {
    static let isDebugRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["VEIL_SNAPSHOT_DIR"] != nil || env["VEIL_FEED_FILE"] != nil
    }()

    static let store: UserDefaults = {
        guard isDebugRun, let suite = UserDefaults(suiteName: "com.aspen.Veil.debug") else { return .standard }
        suite.removePersistentDomain(forName: "com.aspen.Veil.debug")
        return suite
    }()
}
