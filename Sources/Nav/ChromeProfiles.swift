import AppKit
import SwiftUI

/// A Chrome profile from Chrome's "Local State" file.
struct ChromeProfile: Identifiable {
    let id: String          // profile directory, e.g. "Profile 1"
    let name: String
    let email: String?
    let image: NSImage?
    let color: NSColor
    /// Short label, unique among the profiles shown (see `closed()`).
    var label = ""
    var tooltip: String { [name, email].compactMap { $0 }.joined(separator: " · ") }
}

enum ChromeProfiles {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")

    /// Profiles with no Chrome window open, in Chrome's profile-menu order.
    /// Chrome keeps the open ones in `profile.last_active_profiles`.
    static func closed() -> [ChromeProfile] {
        guard let state = localState(), let profile = state["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        let chromeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: TabApp.chrome.bundleID).isEmpty
        let open = chromeRunning ? Set(profile["last_active_profiles"] as? [String] ?? []) : []
        let order = profile["profiles_order"] as? [String] ?? cache.keys.sorted()

        guard Config.current.showsChromeProfiles else { return [] }
        let profiles: [ChromeProfile] = order.compactMap { dir in
            guard !open.contains(dir), let info = cache[dir] else { return nil }
            let picture = root.appendingPathComponent(dir).appendingPathComponent("Google Profile Picture.png")
            let argb = (info["profile_highlight_color"] as? Int) ?? (info["default_avatar_fill_color"] as? Int) ?? 0xFF8E8E93
            return ChromeProfile(id: dir,
                                 name: info["name"] as? String ?? dir,
                                 email: (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 image: NSImage(contentsOf: picture),
                                 color: NSColor(argb: argb))
        }
        return withLabels(profiles)
    }

    /// The email's local part ("avr.nrf"); where several share it, the domain instead
    /// ("gmail", "nstarxinc"); without an email, the profile name.
    private static func withLabels(_ profiles: [ChromeProfile]) -> [ChromeProfile] {
        let locals = profiles.map { $0.email?.split(separator: "@").first.map(String.init) }
        return profiles.enumerated().map { i, p in
            var p = p
            if let local = locals[i], let email = p.email {
                let domain = email.split(separator: "@").last?.split(separator: ".").first.map(String.init) ?? local
                p.label = locals.filter { $0 == local }.count > 1 ? domain : local
            } else {
                p.label = p.name
            }
            return p
        }
    }

    /// Opens a new Chrome window for the profile (Chrome hands it to the running instance).
    static func open(_ profile: ChromeProfile) {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TabApp.chrome.bundleID) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-na", chrome.path, "--args", "--profile-directory=\(profile.id)"]
        try? task.run()
    }

    private static func localState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension NSColor {
    /// Chrome stores colors as signed 32-bit ARGB.
    convenience init(argb: Int) {
        let v = UInt32(truncatingIfNeeded: argb)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Round profile picture (or a colored initial) with a short label; click opens the profile.
struct ChromeProfileButton: View {
    let profile: ChromeProfile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let image = profile.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Text(profile.name.prefix(1).uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: profile.color))
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(nsColor: profile.color), lineWidth: 1.5))
                Text(profile.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 64)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Open \(profile.tooltip)")
    }
}
