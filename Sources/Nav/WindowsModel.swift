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
    /// In its own full-screen Space; the first one gets the F key in the windows view.
    var isFullScreen = false
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
    var automation: AutomationKind?            // e.g. a Playwright-driven Chrome
    var id: pid_t { pid }
}

enum WindowsModel {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Ordinary app windows grouped by app: the pinned apps (most used first), then the
    /// rest, most recently used first.
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
            var info = WindowInfo(id: w.windowID, title: w.title ?? "", frame: w.frame, pid: pid,
                                  bundleID: owner.bundleIdentifier, scWindow: w)
            info.isFullScreen = Spaces.isFullScreen(w.windowID)
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
            groups[g].automation = AutomationKind.of(groups[g].pid)
            if groups[g].windows.first?.bundleID == TabApp.chrome.bundleID,
               groups[g].pid == Tabs.userInstance(of: .chrome)?.processIdentifier {
                groups[g].chromeProfiles = ChromeProfiles.closed()
            }
        }
        let pinned = Set(Config.current.pinnedApps), scores = AppUsage.scores
        func isPinned(_ g: AppWindows) -> Bool { g.automation == nil && g.windows.first?.bundleID.map(pinned.contains) == true }
        func score(_ g: AppWindows) -> Double { g.windows.first?.bundleID.flatMap { scores[$0] } ?? 0 }
        return groups.filter(isPinned).sorted { score($0) > score($1) } + groups.filter { !isPinned($0) }
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
        raise(pid: window.pid, windowID: window.id)
        let running = NSRunningApplication(processIdentifier: window.pid)
        running?.unhide()
        // Launch Services can't tell instances of one app apart (your Chrome vs a
        // Playwright one), so with several running activate the process itself.
        let instances = window.bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).count } ?? 1
        if let url = bundleURL, instances <= 1 {
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

    /// Displays in macOS order (the main display first), as "1 — Name".
    static var displays: [(index: Int, screen: NSScreen)] {
        NSScreen.screens.enumerated().map { ($0.offset + 1, $0.element) }
    }

    /// The display showing most of the window.
    static func display(of window: WindowInfo) -> NSScreen? {
        NSScreen.screens.max { overlap(window.frame, $0) < overlap(window.frame, $1) }
    }

    private static func overlap(_ frame: CGRect, _ screen: NSScreen) -> CGFloat {
        let r = frame.intersection(axRect(screen.frame))
        return r.isNull ? 0 : r.width * r.height
    }

    /// Cocoa (bottom-left origin) → Accessibility / CGWindow (top-left origin) coordinates.
    private static func axRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Moves the window to another display at the same relative place, shrinking it to
    /// fit; a window filling its display fills the new one. Needs Accessibility.
    @discardableResult
    static func move(_ window: WindowInfo, to screen: NSScreen) -> Bool {
        guard let ax = axWindow(for: window) else { return false }
        var origin = window.frame.origin, size = window.frame.size
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &value) == .success {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &value) == .success {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        let from = axRect((display(of: window) ?? NSScreen.screens[0]).visibleFrame)
        let to = axRect(screen.visibleFrame)
        let filled = size.width >= from.width - 4 && size.height >= from.height - 4
        var newSize = filled ? to.size : CGSize(width: min(size.width, to.width), height: min(size.height, to.height))
        func fraction(_ pos: CGFloat, _ start: CGFloat, _ room: CGFloat) -> CGFloat {
            room > 1 ? min(max((pos - start) / room, 0), 1) : 0
        }
        let fx = fraction(origin.x, from.minX, from.width - size.width)
        let fy = fraction(origin.y, from.minY, from.height - size.height)
        var newOrigin = CGPoint(x: to.minX + fx * (to.width - newSize.width), y: to.minY + fy * (to.height - newSize.height))

        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        // Position, size, position again: some apps clamp the size to the display they're on.
        let position = AXValueCreate(.cgPoint, &newOrigin)!
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &newSize)!)
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, position)
        return true
    }

    /// Unminimizes the window, makes it the app's main window and raises it. Needs Accessibility.
    static func raise(pid: pid_t, windowID: CGWindowID) {
        guard let ax = axWindow(pid: pid, id: windowID) else { return }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }

    private static func axWindow(for window: WindowInfo) -> AXUIElement? {
        axWindow(pid: window.pid, id: window.id)
    }

    private static func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        return ((value as? [AXUIElement]) ?? []).first { ax in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(ax, &wid) == .success && wid == id
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

/// Which Space a window is on, through SkyLight's private API (what AltTab does): a window's
/// size can't tell full screen from zoomed, e.g. below the notch with the Dock hidden.
enum Spaces {
    private static let connection = CGSMainConnectionID()

    static func isFullScreen(_ window: CGWindowID) -> Bool {
        let ids = [NSNumber(value: window)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else {
            return false
        }
        return spaces.contains { CGSSpaceGetType(connection, $0.uint64Value) == 4 }   // 4 = full-screen Space
    }
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: Int32, _ space: UInt64) -> Int32
