import AppKit

/// User settings in ~/.config/nav/config.json. Read fresh on every use, so edits apply
/// without restarting. Missing keys fall back to defaults; the file is created with all
/// defaults on first launch.
struct Config: Codable {
    var popupBorder = BorderConfig()
    /// Look of the ⌘⇧E popup: "modern" (light, tab lists + cards) or "classic" (glass previews).
    var theme = "modern"
    /// Modern theme: preview of the window next to the mouse over a tab/window row.
    var hoverPreview = true
    /// Start Nav when you log in (a macOS Login Item).
    var launchAtLogin = true
    /// Keep the macOS Dock hidden while Nav runs; it comes back when Nav quits.
    var hideDock = false
    /// Where closed Chrome profiles are shown next to Chrome's tabs: "left", "right" or "off".
    var chromeProfiles = "right"
    /// ⌘Tab / ⌘⇧Tab open the windows view, and ⌘⇧E shows the macOS app switcher instead.
    var commandTab = true
    /// The app on each of ⌥1…⌥4 (and 1…4 in the windows view), by bundle id; "" (or a
    /// missing entry) leaves that key to the most used app.
    var appKeys: [String] = []
    /// Text editors: their windows get R, F, V (then T, G, B) in the windows view.
    var editorApps = ["dev.zed.Zed", "dev.zed.Zed-Preview", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                      "com.exafunction.windsurf", "com.sublimetext.4", "com.panic.Nova", "com.jetbrains.intellij",
                      "com.jetbrains.WebStorm", "com.jetbrains.pycharm", "com.apple.dt.Xcode", "com.apple.TextEdit",
                      "com.barebones.bbedit"]
    /// Bundle ids always at the top of the windows view (the most used of them first).
    var pinnedApps = ["com.googlecode.iterm2", "com.google.Chrome"]
    /// While a remote desktop / VM app is frontmost, release ⌘E / ⌘⇧E so they reach
    /// the remote machine instead of this Mac's Nav.
    var passShortcutsToRemoteApps = true
    /// Bundle ids that count as remote desktop / VM apps (added to the built-in list).
    var remoteApps: [String] = []

    static let builtInRemoteApps: Set<String> = [
        "com.apple.ScreenSharing",                  // Screen Sharing
        "com.microsoft.rdc.macos",                  // Windows App / Microsoft Remote Desktop
        "com.realvnc.vncviewer",                    // RealVNC Viewer
        "com.philandro.anydesk",                    // AnyDesk
        "com.teamviewer.TeamViewer",                // TeamViewer
        "tv.parsec.www",                            // Parsec
        "com.carriez.rustdesk",                     // RustDesk
        "com.p5sys.jump.mac.viewer",                // Jump Desktop
        "com.p5sys.jump.mac.viewer.web",
        "com.parallels.desktop.console",            // Parallels
        "com.vmware.fusion",                        // VMware Fusion
        "com.utmapp.UTM",                           // UTM
    ]

    var isModern: Bool { theme != "classic" }
    var profilesOnLeft: Bool { chromeProfiles == "left" }
    var showsChromeProfiles: Bool { chromeProfiles != "off" }

    func isRemoteApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Config.builtInRemoteApps.contains(bundleID) || remoteApps.contains(bundleID)
    }

    /// Border around the ⌘⇧E popup.
    struct BorderConfig: Codable {
        var enabled = true
        /// "#RRGGBB", "#RRGGBBAA", or "accent" for the system accent color.
        var color = "accent"
        /// "solid" uses `color`; otherwise a gradient through a palette (see `BorderPalette`).
        var palette = "solid"
        /// Slowly rotate the palette gradient around the border.
        var animate = false
        var width: Double = 4
        /// Also the popup's own corner radius.
        var cornerRadius: Double = 26
        /// Grow (positive) or shrink (negative) the border around the popup, in points.
        var outset: Double = 2
        /// Fade the border out after `duration`; false keeps it while the popup is open.
        var fade = true
        /// Seconds the border stays fully visible before fading.
        var duration: Double = 3
        var fadeIn: Double = 0.15
        var fadeOut: Double = 0.6
        /// Soft glow around the line; 0 turns it off.
        var glow: Double = 12
        var opacity: Double = 1

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = BorderConfig()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
            palette = try c.decodeIfPresent(String.self, forKey: .palette) ?? d.palette
            animate = try c.decodeIfPresent(Bool.self, forKey: .animate) ?? d.animate
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
            cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
            outset = try c.decodeIfPresent(Double.self, forKey: .outset) ?? d.outset
            fade = try c.decodeIfPresent(Bool.self, forKey: .fade) ?? d.fade
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? d.duration
            fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? d.fadeIn
            fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? d.fadeOut
            glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? d.glow
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        }

        var nsColor: NSColor { NSColor(configString: color) ?? .controlAccentColor }

        /// Colors to draw with: the palette's, or just `color`.
        var colors: [NSColor] { BorderPalette.named(palette)?.colors ?? [nsColor] }

        /// Space the line and its glow need outside the popup's edge.
        var margin: CGFloat { enabled ? CGFloat(max(outset, 0) + width + glow) : 0 }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        popupBorder = try c.decodeIfPresent(BorderConfig.self, forKey: .popupBorder) ?? BorderConfig()
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "modern"
        hoverPreview = try c.decodeIfPresent(Bool.self, forKey: .hoverPreview) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        // Older configs: adopt whatever the Dock is set to now.
        hideDock = try c.decodeIfPresent(Bool.self, forKey: .hideDock) ?? MacDock.isHidden
        chromeProfiles = try c.decodeIfPresent(String.self, forKey: .chromeProfiles) ?? "right"
        commandTab = try c.decodeIfPresent(Bool.self, forKey: .commandTab) ?? true
        appKeys = try c.decodeIfPresent([String].self, forKey: .appKeys) ?? []
        editorApps = try c.decodeIfPresent([String].self, forKey: .editorApps) ?? Config().editorApps
        pinnedApps = try c.decodeIfPresent([String].self, forKey: .pinnedApps) ?? Config().pinnedApps
        passShortcutsToRemoteApps = try c.decodeIfPresent(Bool.self, forKey: .passShortcutsToRemoteApps) ?? true
        remoteApps = try c.decodeIfPresent([String].self, forKey: .remoteApps) ?? []
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/nav/config.json")

    static var current: Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("Nav: ignoring invalid \(url.path): \(error)")
            return Config()
        }
    }

    /// Writes the defaults so there is a file to edit. Never overwrites an existing one.
    static func writeDefaultsIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        Config().save()
    }
}

extension NSColor {
    /// "accent", "#RRGGBB" or "#RRGGBBAA".
    convenience init?(configString s: String) {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        if str == "accent" {
            guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
            self.init(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
            return
        }
        let hex = str.hasPrefix("#") ? String(str.dropFirst()) : str
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (v << 8) | 0xFF : v
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}

/// Preset gradients for the border.
struct BorderPalette: Identifiable {
    let id: String
    let name: String
    let hex: [String]
    var colors: [NSColor] { hex.compactMap { NSColor(configString: $0) } }

    static let all: [BorderPalette] = [
        .init(id: "warm", name: "Warm", hex: ["#FF3B30", "#FF9500", "#FFCC00", "#FF6B6B"]),
        .init(id: "sunset", name: "Sunset", hex: ["#FF512F", "#F09819", "#DD2476", "#8E2DE2"]),
        .init(id: "cool", name: "Cool", hex: ["#00C6FF", "#0072FF", "#7F00FF"]),
        .init(id: "ocean", name: "Ocean", hex: ["#00F2FE", "#4FACFE", "#0083B0", "#00B4DB"]),
        .init(id: "neon", name: "Neon", hex: ["#FF00CC", "#3333FF", "#00FFCC"]),
        .init(id: "forest", name: "Forest", hex: ["#A8E063", "#56AB2F", "#1D976C", "#93F9B9"]),
    ]

    static func named(_ id: String) -> BorderPalette? { all.first { $0.id == id.lowercased() } }
}

import ServiceManagement

/// Keeps the macOS Login Item in sync with `Config.launchAtLogin`.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func sync(_ enabled: Bool) {
        // Only a real app bundle can be a login item (not `swift run` / .build binaries).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Nav: login item update failed: \(error)")
        }
    }
}

/// The real macOS Dock, kept out of sight while Nav runs so ⌘E can stand in for it.
enum MacDock {
    /// Auto-hide with a huge reveal delay: the Dock keeps running (⌘Tab, badges,
    /// notifications) but never slides in.
    static let hiddenDelay = 1000.0

    static var isHidden: Bool {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        return prefs?.bool(forKey: "autohide") == true && (prefs?.double(forKey: "autohide-delay") ?? 0) >= hiddenDelay
    }

    static func setHidden(_ hidden: Bool) {
        let commands = hidden
            ? "defaults write com.apple.dock autohide -bool true; defaults write com.apple.dock autohide-delay -float \(hiddenDelay)"
            : "defaults delete com.apple.dock autohide-delay"   // back to normal auto-hide timing
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(commands); killall Dock"]
        try? task.run()
        task.waitUntilExit()
    }
}
