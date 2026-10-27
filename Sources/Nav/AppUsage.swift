import AppKit

/// Which apps you switch to most from the windows view; the top ones get keys 1…4. Each switch adds 1
/// to the app's score after fading every score a little, so the ranking follows your
/// recent habits. Kept in UserDefaults by bundle id.
enum AppUsage {
    private static let key = "appUsage"
    private static let decay = 0.97
    /// Before anything is learned: iTerm2, then Chrome.
    private static let seed = ["com.googlecode.iterm2": 2.0, "com.google.Chrome": 1.0]

    static var scores: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? seed }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func record(_ bundleID: String?) {
        guard let bundleID else { return }
        var s = scores.mapValues { $0 * decay }.filter { $0.value > 0.01 }
        s[bundleID, default: 0] += 1
        scores = s
    }

    /// The `n` most used apps that are running (your own instances, not automated ones).
    static func running(_ n: Int) -> [NSRunningApplication] {
        let scores = scores
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier, scores[id] != nil,
                      AutomationKind.of(app.processIdentifier) == nil else { return false }
                return seen.insert(id).inserted
            }
            .sorted { scores[$0.bundleIdentifier!]! > scores[$1.bundleIdentifier!]! }
            .prefix(n).map { $0 }
    }

    /// ⌥Tab: from app 1 to app 2, from anywhere else to app 1.
    static func switchTopTwo() {
        let top = running(2)
        guard let first = top.first else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = front == first.processIdentifier && top.count > 1 ? top[1] : first
        app.unhide()
        // Launch Services brings the app's front window forward; with several instances
        // (your Chrome and a Playwright one) it can't tell them apart, so activate the process.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier ?? "").count
        if let url = app.bundleURL, instances <= 1 {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            app.activate()
        }
    }
}
