import AppKit

/// Apps whose tabs Nav can list and switch to, via their AppleScript dictionaries.
enum TabApp: String, CaseIterable {
    case iTerm = "com.googlecode.iterm2"
    case chrome = "com.google.Chrome"

    var bundleID: String { rawValue }
}

struct TabInfo: Identifiable {
    let app: TabApp
    let scriptWindowID: Int    // the app's own window id (iTerm2: same as CGWindowID)
    let index: Int             // 1-based, as in AppleScript
    let title: String
    let url: String?
    let isCurrent: Bool
    var isAudible = false
    var id: String { "t-\(app.rawValue)-\(scriptWindowID)-\(index)" }

    /// "github.com" for https://www.github.com/…
    var domain: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One app window as AppleScript sees it.
struct TabWindow {
    let app: TabApp
    let scriptID: Int
    let bounds: CGRect?        // global, top-left origin (same space as CGWindow frames)
    var tabs: [TabInfo]
}

enum Tabs {
    /// Last fetched tabs. An AppleScript round trip takes ~0.3 s, so popups open
    /// with these and swap in fresh ones when they arrive.
    static var cached: [TabWindow] = []   // main thread only

    static func fetchAll() async -> [TabWindow] {
        async let iTerm = fetch(.iTerm)
        async let chrome = fetch(.chrome)
        return await iTerm + chrome
    }

    static func fetch(_ app: TabApp) async -> [TabWindow] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty,
              automationAllowed(app) else { return [] }
        // One line per tab: window id, bounds, index, current, title, url — tab separated.
        let script: String
        switch app {
        case .iTerm:
            script = """
            tell application id "\(app.bundleID)"
                set sep to character id 9
                set out to ""
                repeat with w in windows
                    set cur to unique id of current session of current tab of w
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        set s to current session of t
                        set out to out & (id of w) & sep & sep & i & sep & ((unique id of s) is cur) & sep & (name of s) & sep & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        case .chrome:
            // Bulk property reads: two Apple Events per window instead of two per tab.
            script = """
            tell application id "\(app.bundleID)"
                set sep to character id 9
                set out to ""
                repeat with w in windows
                    set b to bounds of w
                    set bs to ((item 1 of b) as text) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
                    set ai to active tab index of w
                    set titles to title of every tab of w
                    set urls to URL of every tab of w
                    repeat with i from 1 to count of titles
                        set out to out & (id of w) & sep & bs & sep & i & sep & (i = ai) & sep & (item i of titles) & sep & (item i of urls) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        }

        var windows: [TabWindow] = []
        for line in await osascript(script, timeout: 1.5).split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let wid = Int(f[0]), let index = Int(f[2]) else { continue }
            let tab = TabInfo(app: app, scriptWindowID: wid, index: index, title: f[4],
                              url: f[5].isEmpty ? nil : f[5], isCurrent: f[3] == "true")
            if windows.last?.scriptID == wid {
                windows[windows.count - 1].tabs.append(tab)
            } else {
                windows.append(TabWindow(app: app, scriptID: wid, bounds: parseBounds(f[1]), tabs: [tab]))
            }
        }
        if app == .chrome { markAudibleChromeTabs(&windows) }
        return windows
    }

    /// Gives each system window of one app its tabs. Each scripted window is used at
    /// most once: iTerm2 matches by id; Chrome by title + frame, then title, then frame
    /// (the window title is the active tab's; maximized windows all share one frame).
    static func assign(to windows: inout [WindowInfo], from snapshot: [TabWindow]) {
        for i in windows.indices { windows[i].tabs = [] }
        guard let app = windows.first?.bundleID.flatMap(TabApp.init(rawValue:)) else { return }
        var candidates = snapshot.filter { $0.app == app }

        func sameFrame(_ w: TabWindow, _ frame: CGRect) -> Bool {
            guard let b = w.bounds else { return false }
            return abs(b.minX - frame.minX) < 4 && abs(b.minY - frame.minY) < 4
                && abs(b.width - frame.width) < 4 && abs(b.height - frame.height) < 4
        }
        func sameTitle(_ w: TabWindow, _ title: String) -> Bool {
            w.tabs.contains { $0.isCurrent && titleMatches(window: title, tab: $0.title) }
        }
        let passes: [(TabWindow, WindowInfo) -> Bool] = app == .iTerm
            ? [{ t, w in t.scriptID == Int(w.id) }]
            : [{ t, w in sameTitle(t, w.title) && sameFrame(t, w.frame) },
               { t, w in sameTitle(t, w.title) },
               { t, w in sameFrame(t, w.frame) }]
        let scripted = !candidates.isEmpty
        for matches in passes {
            for i in windows.indices where windows[i].tabs.isEmpty {
                if let c = candidates.firstIndex(where: { matches($0, windows[i]) }) {
                    windows[i].tabs = candidates.remove(at: c).tabs
                }
            }
        }
        // The app's own list is authoritative: off-screen leftovers are ghosts
        // (windows on other Spaces are in that list and matched above).
        if scripted { windows.removeAll { $0.tabs.isEmpty && !$0.scWindow.isOnScreen } }
    }

    /// System window titles get extras ("… 🔊" for audio) and are cut in the
    /// middle with "…" when long, so compare loosely.
    static func titleMatches(window: String, tab: String) -> Bool {
        var w = window.trimmingCharacters(in: .whitespaces)
        for suffix in ["🔊", "🔇", "🎤", "📹"] where w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !w.isEmpty, !tab.isEmpty else { return false }
        if let cut = w.range(of: "…") {
            return tab.hasPrefix(w[..<cut.lowerBound]) && tab.hasSuffix(w[cut.upperBound...])
        }
        return w == tab
    }

    /// Same tab still open? Matched by title, since indexes shift when tabs close.
    static func hasTab(_ tab: TabInfo, in snapshot: [TabWindow]) -> Bool {
        snapshot.contains { w in
            w.app == tab.app && w.scriptID == tab.scriptWindowID && w.tabs.contains { $0.title == tab.title }
        }
    }

    /// Selects the tab, brings its window to the front and activates the app.
    static func select(_ tab: TabInfo) {
        let id = tab.app.bundleID
        let script: String
        switch tab.app {
        case .iTerm:
            script = """
            tell application id "\(id)"
                tell window id \(tab.scriptWindowID)
                    select tab \(tab.index)
                    select
                end tell
                activate
            end tell
            """
        case .chrome:
            script = """
            tell application id "\(id)"
                set active tab index of window id \(tab.scriptWindowID) to \(tab.index)
                set index of window id \(tab.scriptWindowID) to 1
                activate
            end tell
            """
        }
        Task { await osascript(script) }
    }

    static func close(_ tab: TabInfo) {
        let script = """
        tell application id "\(tab.app.bundleID)" to close tab \(tab.index) of window id \(tab.scriptWindowID)
        """
        Task { await osascript(script) }
    }

    /// Chrome's AppleScript doesn't say which tabs play sound, but its tab strip does:
    /// each tab's accessibility name ends in " - Audio playing". Needs Accessibility.
    private static func markAudibleChromeTabs(_ windows: inout [TabWindow]) {
        guard AXIsProcessTrusted(),
              let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: TabApp.chrome.bundleID).first
        else { return }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        let strips: [[String]] = (axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap { window in
            guard let group = findTabGroup(window, depth: 0) else { return nil }
            return (axValue(group, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .filter { axValue($0, kAXRoleAttribute) as? String == kAXRadioButtonRole }
                .map { axValue($0, kAXTitleAttribute) as? String ?? "" }
        }
        // Pair each scripted window with the tab strip whose names start with its tab titles.
        var unused = strips
        for w in windows.indices {
            guard let s = unused.firstIndex(where: { names in
                names.count == windows[w].tabs.count && zip(names, windows[w].tabs).allSatisfy { $0.hasPrefix($1.title) }
            }) else { continue }
            let names = unused.remove(at: s)
            for t in windows[w].tabs.indices { windows[w].tabs[t].isAudible = names[t].contains(" - Audio playing") }
        }
    }

    private static func findTabGroup(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if axValue(element, kAXRoleAttribute) as? String == kAXTabGroupRole { return element }
        guard depth < 12 else { return nil }
        for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = findTabGroup(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }

    private static func parseBounds(_ s: String) -> CGRect? {
        let n = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    /// True once Nav may send Apple Events to the app. The first time, it asks
    /// in the background and returns false, so popups never wait on the dialog.
    private static func automationAllowed(_ app: TabApp) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleID)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        if status == OSStatus(errAEEventWouldRequireUserConsent) {
            DispatchQueue.global().async {
                _ = AEDeterminePermissionToAutomateTarget(target.aeDesc!, typeWildCard, typeWildCard, true)
            }
        }
        return status == noErr
    }

    /// Runs AppleScript out of process so a slow/blocked app never stalls the UI.
    @discardableResult
    private static func osascript(_ source: String, timeout: TimeInterval? = nil) async -> String {
        await withCheckedContinuation { cont in
            let task = Process()
            let out = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]
            task.standardOutput = out
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { cont.resume(returning: ""); return }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if task.isRunning { task.terminate() }
                }
            }
            // Drain while it runs: output bigger than the pipe buffer (lots of tabs) would block it.
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
