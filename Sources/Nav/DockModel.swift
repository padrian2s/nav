import AppKit

struct DockItem: Identifiable {
    enum Kind { case app, folder, trash }

    let id: String
    let kind: Kind
    let url: URL
    let name: String
    let icon: NSImage
    var isRunning: Bool
    var bundleID: String?
    var isAudible = false
}

/// Reads the real Dock configuration so the popup mirrors it.
enum DockModel {
    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    static let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    /// Sections in Dock order: [Finder + pinned], [recent/running], [stacks + Trash]
    static func load() -> [[DockItem]] {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })
        let playing = AudioActivity.playingApps()
        let audibleIDs = Set(running.filter { playing.contains($0.processIdentifier) }.compactMap { $0.bundleIdentifier })

        var pinnedURLs = [finderURL]
        pinnedURLs += urls(from: prefs?.array(forKey: "persistent-apps"))
        let pinnedPaths = Set(pinnedURLs.map { $0.standardizedFileURL.path })

        let pinned = pinnedURLs.map { appItem($0, running: runningIDs, audible: audibleIDs) }

        let showRecents = prefs?.object(forKey: "show-recents") as? Bool ?? true
        let pinnedIDs = Set(pinnedURLs.compactMap { Bundle(url: $0)?.bundleIdentifier })
        var recentURLs: [URL] = running
            .filter { !pinnedIDs.contains($0.bundleIdentifier ?? "") }
            .compactMap { $0.bundleURL }
        if showRecents {
            for url in urls(from: prefs?.array(forKey: "recent-apps"))
            where !pinnedPaths.contains(url.standardizedFileURL.path)
                && !recentURLs.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                recentURLs.append(url)
            }
        }
        let recent = recentURLs.map { appItem($0, running: runningIDs, audible: audibleIDs) }

        var others = urls(from: prefs?.array(forKey: "persistent-others")).map { url in
            DockItem(id: url.path, kind: .folder, url: url, name: displayName(url),
                     icon: icon(for: url), isRunning: false)
        }
        others.append(trashItem())

        return [pinned, recent, others].filter { !$0.isEmpty }
    }

    private static func urls(from tiles: [Any]?) -> [URL] {
        (tiles ?? []).compactMap { tile in
            guard let tile = tile as? [String: Any],
                  let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let str = file["_CFURLString"] as? String,
                  let url = URL(string: str), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    private static func appItem(_ url: URL, running: Set<String>, audible: Set<String>) -> DockItem {
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let image = bundleID == "com.apple.iCal" ? CalendarIcon.make() : icon(for: url)
        return DockItem(id: url.path, kind: .app, url: url, name: displayName(url), icon: image,
                        isRunning: bundleID.map(running.contains) ?? false, bundleID: bundleID,
                        isAudible: bundleID.map(audible.contains) ?? false)
    }

    private static func trashItem() -> DockItem {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        let full = contents.contains { $0 != ".DS_Store" }
        let image = NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? icon(for: trashURL)
        return DockItem(id: "trash", kind: .trash, url: trashURL, name: "Trash", icon: image, isRunning: false)
    }

    private static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 256, height: 256)
        return image
    }

    private static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Live-date calendar icon, like the real Dock draws it.
enum CalendarIcon {
    static func make(date: Date = Date()) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 20, dy: 20)
            let path = NSBezierPath(roundedRect: inset, xRadius: 50, yRadius: 50)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            let weekday = DateFormatter()
            weekday.dateFormat = "EEE"
            let day = Calendar.current.component(.day, from: date)

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let top: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 44, weight: .medium),
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: style,
            ]
            let big: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 128, weight: .regular),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
                .paragraphStyle: style,
            ]
            weekday.string(from: date).draw(in: NSRect(x: inset.minX, y: inset.maxY - 70, width: inset.width, height: 56), withAttributes: top)
            "\(day)".draw(in: NSRect(x: inset.minX, y: inset.minY + 10, width: inset.width, height: 150), withAttributes: big)
            return true
        }
    }
}
