import AppKit
import ScreenCaptureKit

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let pid: pid_t
    let scWindow: SCWindow
    var image: NSImage?
    var tabs: [TabInfo] = []   // iTerm2 only: shown as a compact list instead of a preview
}

struct TabInfo: Identifiable {
    let windowID: CGWindowID
    let index: Int             // 1-based, as in iTerm2's AppleScript
    let title: String
    let isCurrent: Bool
    var id: String { "t\(windowID)-\(index)" }
}

/// Something you can switch to: a window, or one iTerm2 tab of a window.
struct SwitchTarget: Identifiable {
    let window: WindowInfo
    let tab: TabInfo?
    var id: String { tab?.id ?? "w\(window.id)" }
}

struct AppWindows: Identifiable {
    let pid: pid_t
    let name: String
    let icon: NSImage
    let bundleURL: URL?
    var windows: [WindowInfo]
    var id: pid_t { pid }
}

enum WindowsModel {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Ordinary app windows grouped by app, most recently used app first.
    static func load(iTermTabs: [CGWindowID: [TabInfo]]) async throws -> [AppWindows] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)

        // CGWindowList is ordered front-to-back; use it for recency.
        let order = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        let me = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { w in
            guard w.windowLayer == 0, w.frame.width >= 100, w.frame.height >= 60,
                  let app = w.owningApplication, app.processID != me,
                  NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular
            else { return false }
            // Off-screen untitled windows are usually helpers, not real windows.
            return w.isOnScreen || !(w.title ?? "").isEmpty
        }
        .sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }

        var groups: [AppWindows] = []
        var index: [pid_t: Int] = [:]
        for w in windows {
            guard let owner = w.owningApplication else { continue }
            let pid = owner.processID
            var info = WindowInfo(id: w.windowID, title: w.title ?? "", frame: w.frame, pid: pid, scWindow: w)
            if owner.bundleIdentifier == ITerm.bundleID {
                info.tabs = iTermTabs[w.windowID] ?? []
            }
            if let i = index[pid] {
                groups[i].windows.append(info)
            } else {
                let running = NSRunningApplication(processIdentifier: pid)
                let icon = running?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                    ?? running?.icon ?? NSWorkspace.shared.icon(for: .application)
                index[pid] = groups.count
                groups.append(AppWindows(pid: pid, name: running?.localizedName ?? owner.applicationName,
                                         icon: icon, bundleURL: running?.bundleURL, windows: [info]))
            }
        }
        return groups
    }

    static func thumbnail(of window: WindowInfo, maxSize: CGSize) async -> NSImage? {
        let scale = min(maxSize.width / window.frame.width, maxSize.height / window.frame.height, 1)
        let config = SCStreamConfiguration()
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window.scWindow)
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Brings one specific window to the front. Raising a single window needs
    /// Accessibility; without it, only the app is activated.
    static func focus(_ window: WindowInfo, bundleURL: URL?) {
        if let ax = axWindow(for: window) {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
        let running = NSRunningApplication(processIdentifier: window.pid)
        running?.unhide()
        if let url = bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            running?.activate()
        }
    }

    /// Presses the window's close button, like clicking the red dot (the app may
    /// still ask to save). Needs Accessibility.
    @discardableResult
    static func close(_ window: WindowInfo) -> Bool {
        guard let ax = axWindow(for: window) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    private static func axWindow(for window: WindowInfo) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        return ((value as? [AXUIElement]) ?? []).first { ax in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(ax, &wid) == .success && wid == window.id
        }
    }

    /// Asks once per launch for Accessibility (needed to raise a specific window).
    static func requestAccessibilityIfNeeded(force: Bool = false) {
        guard !AXIsProcessTrusted(), force || !askedForAccessibility else { return }
        askedForAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    private static var askedForAccessibility = false
}

/// iTerm2 tabs via its AppleScript dictionary (window ids there are CGWindowIDs).
enum ITerm {
    static let bundleID = "com.googlecode.iterm2"

    /// Last fetched tabs. The AppleScript round trip takes ~0.3 s, so the popup
    /// opens with these and swaps in fresh ones when they arrive.
    @MainActor static var cached: [CGWindowID: [TabInfo]] = [:]

    static func tabs() async -> [CGWindowID: [TabInfo]] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              automationAllowed() else { return [:] }
        let script = """
        tell application id "\(bundleID)"
            set out to ""
            repeat with w in windows
                set cur to unique id of current session of current tab of w
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set s to current session of t
                    set out to out & (id of w) & character id 9 & i & character id 9 & ((unique id of s) is cur) & character id 9 & (name of s) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        var result: [CGWindowID: [TabInfo]] = [:]
        for line in await osascript(script, timeout: 1.5).split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let wid = CGWindowID(f[0]), let index = Int(f[1]) else { continue }
            result[wid, default: []].append(TabInfo(windowID: wid, index: index, title: String(f[3]), isCurrent: f[2] == "true"))
        }
        return result
    }

    /// Selects the tab, brings its window to the front and activates iTerm2.
    static func select(_ tab: TabInfo) {
        Task {
            await osascript("""
            tell application id "\(bundleID)"
                tell window id \(tab.windowID)
                    select tab \(tab.index)
                    select
                end tell
                activate
            end tell
            """)
        }
    }

    /// Same tab still open? Matched by title, since indexes shift when tabs close.
    static func hasTab(_ tab: TabInfo, in tabs: [CGWindowID: [TabInfo]]) -> Bool {
        tabs[tab.windowID]?.contains { $0.title == tab.title } ?? false
    }

    static func close(_ tab: TabInfo) {
        Task {
            await osascript("""
            tell application id "\(bundleID)" to tell window id \(tab.windowID) to close tab \(tab.index)
            """)
        }
    }

    /// True once Nav may send Apple Events to iTerm2. The first time, it asks
    /// in the background and returns false, so the popup never waits on the dialog.
    private static func automationAllowed() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        if status == OSStatus(errAEEventWouldRequireUserConsent) {
            DispatchQueue.global().async {
                _ = AEDeterminePermissionToAutomateTarget(target.aeDesc!, typeWildCard, typeWildCard, true)
            }
        }
        return status == noErr
    }

    /// Runs AppleScript out of process so a slow/blocked iTerm2 never stalls the UI.
    @discardableResult
    private static func osascript(_ source: String, timeout: TimeInterval? = nil) async -> String {
        await withCheckedContinuation { cont in
            let task = Process()
            let out = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]
            task.standardOutput = out
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try task.run() } catch { cont.resume(returning: ""); return }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if task.isRunning { task.terminate() }
                }
            }
        }
    }
}

/// Private but long-stable API (used by AltTab, Hammerspoon, etc.) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
