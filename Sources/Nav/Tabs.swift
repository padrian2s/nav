import AppKit
import ScriptingBridge

/// Apps whose tabs Nav can list and switch to, via their AppleScript dictionaries.
enum TabApp: String, CaseIterable {
    case iTerm = "com.googlecode.iterm2"
    case chrome = "com.google.Chrome"

    var bundleID: String { rawValue }
}

struct TabInfo: Identifiable {
    let app: TabApp
    let pid: pid_t             // the app instance it belongs to (there can be several Chromes)
    let scriptWindowID: Int    // the app's own window id (iTerm2: same as CGWindowID)
    let index: Int             // 1-based, as in AppleScript
    let title: String
    let url: String?
    let isCurrent: Bool
    var isAudible = false
    var id: String { "t-\(app.rawValue)-\(pid)-\(scriptWindowID)-\(index)" }

    /// "github.com" for https://www.github.com/…
    var domain: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One app window as AppleScript sees it.
struct TabWindow {
    let app: TabApp
    let pid: pid_t
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
        guard let instance = userInstance(of: app), automationAllowed(app) else { return [] }
        var windows = app == .chrome ? fetchChrome(instance.processIdentifier)
                                     : await fetchITerm(instance.processIdentifier)
        if app == .chrome { markAudibleChromeTabs(&windows, pid: instance.processIdentifier) }
        return windows
    }

    /// The instance the user works in. Automation tools (Playwright, Puppeteer, …) start
    /// extra Chromes with their own profile folder; those are ignored.
    static func userInstance(of app: TabApp) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .filter { !ProcessInfo.isAutomated($0.processIdentifier) }
            .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    private static func fetchITerm(_ pid: pid_t) async -> [TabWindow] {
        let script = """
        tell application id "\(TabApp.iTerm.bundleID)"
            set sep to character id 9
            set out to ""
            repeat with w in windows
                set cur to unique id of current session of current tab of w
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set s to current session of t
                    set out to out & (id of w) & sep & i & sep & ((unique id of s) is cur) & sep & (name of s) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        var windows: [TabWindow] = []
        for line in await osascript(script, timeout: 1.5).split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let wid = Int(f[0]), let index = Int(f[1]) else { continue }
            let tab = TabInfo(app: .iTerm, pid: pid, scriptWindowID: wid, index: index, title: f[3],
                              url: nil, isCurrent: f[2] == "true")
            if windows.last?.scriptID == wid {
                windows[windows.count - 1].tabs.append(tab)
            } else {
                windows.append(TabWindow(app: .iTerm, pid: pid, scriptID: wid, bounds: nil, tabs: [tab]))
            }
        }
        return windows
    }

    /// Scripting Bridge addresses one process by pid, unlike `tell application`,
    /// which may pick an automation Chrome. Bulk reads: two Apple Events per window.
    private static func fetchChrome(_ pid: pid_t) -> [TabWindow] {
        guard let chrome = SBApplication(processIdentifier: pid),
              let windows = chrome.value(forKey: "windows") as? SBElementArray else { return [] }
        chrome.timeout = 90   // ticks (1/60 s)
        return windows.compactMap { element -> TabWindow? in
            guard let window = element as? SBObject,
                  let wid = scriptID(window.value(forKey: "id")),
                  let tabs = window.value(forKey: "tabs") as? SBElementArray,
                  let titles = tabs.value(forKey: "title") as? [String] else { return nil }
            let urls = tabs.value(forKey: "URL") as? [String] ?? []
            let active = window.value(forKey: "activeTabIndex") as? Int ?? 0
            let bounds = (window.value(forKey: "bounds") as? NSValue)?.rectValue
            let infos = titles.enumerated().map { i, title in
                TabInfo(app: .chrome, pid: pid, scriptWindowID: wid, index: i + 1, title: title,
                        url: urls.indices.contains(i) && !urls[i].isEmpty ? urls[i] : nil, isCurrent: i + 1 == active)
            }
            return TabWindow(app: .chrome, pid: pid, scriptID: wid, bounds: bounds, tabs: infos)
        }
    }

    /// Chrome's window `id` is text in its dictionary ("32380644").
    private static func scriptID(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? String).flatMap(Int.init)
    }

    private static func chromeWindow(_ tab: TabInfo) -> (SBApplication, SBObject)? {
        guard let chrome = SBApplication(processIdentifier: tab.pid),
              let windows = chrome.value(forKey: "windows") as? SBElementArray,
              let window = windows.object(withID: String(tab.scriptWindowID)) as? SBObject else { return nil }   // Chrome ids are text
        return (chrome, window)
    }

    /// Gives each system window of one app its tabs. Each scripted window is used at
    /// most once: iTerm2 matches by id; Chrome by title + frame, then title, then frame
    /// (the window title is the active tab's; maximized windows all share one frame).
    static func assign(to windows: inout [WindowInfo], from snapshot: [TabWindow]) {
        for i in windows.indices { windows[i].tabs = [] }
        guard let app = windows.first?.bundleID.flatMap(TabApp.init(rawValue:)) else { return }
        let pid = windows.first?.pid
        var candidates = snapshot.filter { $0.app == app && $0.pid == pid }

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
        // Untitled ones (or titled just "Google Chrome") are internal windows with no tabs.
        let appName = windows.first?.scWindow.owningApplication?.applicationName ?? ""
        if scripted {
            windows.removeAll { w in
                w.tabs.isEmpty && (!w.scWindow.isOnScreen || w.title.isEmpty || w.title == appName)
            }
        }
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
            w.app == tab.app && w.pid == tab.pid && w.scriptID == tab.scriptWindowID && w.tabs.contains { $0.title == tab.title }
        }
    }

    /// Selects the tab, brings its window to the front and activates the app.
    static func select(_ tab: TabInfo) {
        switch tab.app {
        case .iTerm:
            Task {
                await osascript("""
                tell application id "\(tab.app.bundleID)"
                    tell window id \(tab.scriptWindowID)
                        select tab \(tab.index)
                        select
                    end tell
                    activate
                end tell
                """)
                // AppleScript's `select` doesn't always bring the window forward (e.g. when
                // another iTerm2 window is zoomed over it). Its window id is the system
                // window number, so raise that window directly too.
                await MainActor.run {
                    WindowsModel.raise(pid: tab.pid, windowID: CGWindowID(tab.scriptWindowID))
                    NSRunningApplication(processIdentifier: tab.pid)?.activate()
                }
            }
        case .chrome:
            DispatchQueue.global().async {
                guard let (chrome, window) = chromeWindow(tab) else { return }
                window.setValue(tab.index, forKey: "activeTabIndex")
                window.setValue(1, forKey: "index")
                chrome.activate()
            }
        }
    }

    static func close(_ tab: TabInfo) {
        switch tab.app {
        case .iTerm:
            Task {
                await osascript("""
                tell application id "\(tab.app.bundleID)" to close tab \(tab.index) of window id \(tab.scriptWindowID)
                """)
            }
        case .chrome:
            DispatchQueue.global().async {
                guard let (_, window) = chromeWindow(tab),
                      let tabs = window.value(forKey: "tabs") as? SBElementArray,
                      tabs.count >= tab.index, let t = tabs.object(at: tab.index - 1) as? SBObject else { return }
                _ = (t as AnyObject).perform(Selector(("close")))
            }
        }
    }

    /// Chrome's AppleScript doesn't say which tabs play sound, but its tab strip does:
    /// each tab's accessibility name ends in " - Audio playing". Needs Accessibility.
    private static func markAudibleChromeTabs(_ windows: inout [TabWindow], pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
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

extension ProcessInfo {
    /// Launched by an automation tool: remote debugging, a throwaway profile folder,
    /// headless or --enable-automation (Playwright, Puppeteer, Selenium, …).
    static func isAutomated(_ pid: pid_t) -> Bool {
        arguments(of: pid).contains { arg in
            ["--remote-debugging", "--user-data-dir", "--enable-automation", "--headless"].contains { arg.hasPrefix($0) }
        }
    }

    /// Command-line arguments of another process (KERN_PROCARGS2: argc, exec path, padding, argv).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }      // exec path
        while i < size && buffer[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return Array(args.dropFirst())                    // argv[0] is the program
    }
}

/// Which tool drives an automated browser, for its badge.
struct AutomationKind {
    let name: String
    let symbol: String   // SF Symbol
    let color: NSColor

    static func of(_ pid: pid_t) -> AutomationKind? {
        guard ProcessInfo.isAutomated(pid) else { return nil }
        let args = ProcessInfo.arguments(of: pid).joined(separator: " ").lowercased()
        if args.contains("playwright") {
            return AutomationKind(name: "Playwright", symbol: "theatermasks.fill", color: NSColor(srgbRed: 0.18, green: 0.68, blue: 0.2, alpha: 1))
        }
        if args.contains("puppeteer") {
            return AutomationKind(name: "Puppeteer", symbol: "figure.wave", color: .systemTeal)
        }
        return AutomationKind(name: "Automation", symbol: "gearshape.2.fill", color: .systemGray)
    }
}
