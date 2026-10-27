import AppKit
import SwiftUI

/// Brief "⌥1 iTerm2" card over the window you just switched to with ⌥1…⌥4 / ⌥Tab.
/// Doesn't take focus or clicks, and fades out on its own.
enum SwitchHUD {
    private static let panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }()
    private static var generation = 0

    static func show(_ app: NSRunningApplication, key: String) {
        generation += 1
        let gen = generation
        // Give the app a moment to bring its window forward, then center on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard gen == generation else { return }
            let host = NSHostingView(rootView: HUDView(icon: app.icon ?? NSImage(), name: app.localizedName ?? "", key: key))
            let size = host.fittingSize
            let area = frontWindowFrame(of: app.processIdentifier)
                ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.frame
                ?? NSScreen.main?.frame ?? .zero
            panel.contentView = host
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard gen == generation else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.35
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    if gen == generation { panel.orderOut(nil) }
                })
            }
        }
    }

    /// The app's frontmost ordinary window, in Cocoa coordinates.
    private static func frontWindowFrame(of pid: pid_t) -> NSRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 100
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct HUDView: View {
    let icon: NSImage
    let name: String
    let key: String

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 96, height: 96)
            Text(name).font(.system(size: 20, weight: .semibold))
            Text(key)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(.primary.opacity(0.12)))
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .frame(minWidth: 200)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        .padding(8)
    }
}
