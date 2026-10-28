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

    static let keyCount = 4

    /// Which app each of ⌥1…⌥4 (and 1…4 in the windows view) goes to: the one picked in
    /// Settings, or, for a key left on "Most used", the most used of `available` not on another key.
    static func slots(available: [String], fixed: [String] = Config.current.appKeys) -> [String?] {
        let fixed = Array((fixed + Array(repeating: "", count: keyCount)).prefix(keyCount))
        let scores = scores
        var learned = Set(available).filter { scores[$0] != nil && !fixed.contains($0) }
            .sorted { scores[$0]! > scores[$1]! }.makeIterator()
        return fixed.map { $0.isEmpty ? learned.next() : $0 }
    }

    /// Your own running apps by bundle id (not automated ones, like a Playwright Chrome).
    private static func runningApps() -> [String: NSRunningApplication] {
        var apps: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && AutomationKind.of(app.processIdentifier) == nil {
            if let id = app.bundleIdentifier, apps[id] == nil { apps[id] = app }
        }
        return apps
    }

    /// What ⌥1…⌥4 go to right now.
    static func currentSlots() -> [String?] { slots(available: Array(runningApps().keys)) }

    static func name(of bundleID: String) -> String {
        if let app = runningApps()[bundleID], let name = app.localizedName { return name }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    /// ⌥Tab: from app 1 to app 2, from anywhere else to app 1.
    static func switchTopTwo() {
        let s = currentSlots()
        guard let first = s[0] else { return }
        let second = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == first && s[1] != nil
        open(second ? s[1]! : first, key: second ? "⌥2" : "⌥1")
    }

    /// ⌥1…⌥4: key `n` (0 = ⌥1).
    static func switchTo(_ n: Int) {
        if let id = currentSlots()[n] { open(id, key: "⌥\(n + 1)") }
    }

    /// Brings the app forward, or launches it (an app picked in Settings that isn't running).
    static func open(_ bundleID: String, key: String) {
        if let app = runningApps()[bundleID] { return activate(app, key: key) }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, _ in
            if let app { DispatchQueue.main.async { SwitchHUD.show(app, key: key) } }
        }
    }

    private static func activate(_ app: NSRunningApplication, key: String) {
        SwitchHUD.show(app, key: key)
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
