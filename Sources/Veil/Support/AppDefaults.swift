import Foundation

/// The UserDefaults Veil reads and writes. The developer snapshot / feed tools run against a throw-away
/// suite so they can never touch the real user's settings or usage counters.
enum AppDefaults {
    static let isDebugRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["VEIL_SNAPSHOT_DIR"] != nil || env["VEIL_FEED_FILE"] != nil || env["VEIL_MIC_PROBE"] != nil || env["VEIL_STYLE_LAB"] != nil
    }()

    static let store: UserDefaults = {
        guard isDebugRun, let suite = UserDefaults(suiteName: "com.aspen.Veil.debug") else { return .standard }
        suite.removePersistentDomain(forName: "com.aspen.Veil.debug")
        // Lets a test start from settings saved by an older version (migration checks).
        if let seed = ProcessInfo.processInfo.environment["VEIL_SEED_PREFS"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: seed)) {
            suite.set(data, forKey: "preferences.v1")
        }
        return suite
    }()
}
