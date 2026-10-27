import AppKit

/// Which apps you switch to most from the windows view, for ⌘1…⌘4. Each switch adds 1
/// to the app's score after fading every score a little, so the ranking follows your
/// recent habits. Kept in UserDefaults by bundle id.
enum AppUsage {
    private static let key = "appUsage"
    private static let decay = 0.97
    /// Before anything is learned: iTerm2, then Chrome.
    private static let seed = ["com.googlecode.iterm2": 2.0, "com.google.Chrome": 1.0]

    private static var scores: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? seed }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func record(_ bundleID: String?) {
        guard let bundleID else { return }
        var s = scores.mapValues { $0 * decay }.filter { $0.value > 0.01 }
        s[bundleID, default: 0] += 1
        scores = s
    }

    /// Bundle ids, most used first.
    static func top(_ n: Int) -> [String] {
        scores.sorted { $0.value > $1.value }.prefix(n).map(\.key)
    }

    static func name(of bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
    }
}
