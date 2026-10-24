import AppKit
import ScreenCaptureKit

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let pid: pid_t
    let bundleID: String?
    let scWindow: SCWindow
    var image: NSImage?
    var tabs: [TabInfo] = []   // iTerm2 / Chrome: shown as a compact list instead of a preview
}

/// Something you can switch to: a window, or one tab of a window.
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
    var isAudible = false
    var chromeProfiles: [ChromeProfile] = []   // Chrome only: profiles with no window open
    var id: pid_t { pid }
}

enum WindowsModel {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Ordinary app windows grouped by app, most recently used app first.
    static func load(tabs snapshot: [TabWindow]) async throws -> [AppWindows] {
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
            let info = WindowInfo(id: w.windowID, title: w.title ?? "", frame: w.frame, pid: pid,
                                  bundleID: owner.bundleIdentifier, scWindow: w)
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
        let playing = AudioActivity.playingApps()
        for g in groups.indices {
            Tabs.assign(to: &groups[g].windows, from: snapshot)
            groups[g].isAudible = playing.contains(groups[g].pid)
            if groups[g].windows.first?.bundleID == TabApp.chrome.bundleID {
                groups[g].chromeProfiles = ChromeProfiles.closed()
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

/// Private but long-stable API (used by AltTab, Hammerspoon, etc.) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
