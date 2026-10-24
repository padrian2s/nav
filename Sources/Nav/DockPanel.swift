import AppKit
import SwiftUI

/// Borderless floating panel that can take key focus (for Esc / arrows)
/// without activating Nav, so focus returns to the previous app on dismiss.
final class DockPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    // ⌘-shortcuts arrive here, not in keyDown (there is no menu bar to handle them).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), onKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private var mouseMonitor: Any?

    /// Shows the panel centered horizontally on the cursor, with the cursor
    /// `anchorY` points above the panel's bottom edge, clamped to the screen.
    func present(size: NSSize, anchorY: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - anchorY)
        let vf = screen.visibleFrame
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)

        setFrame(NSRect(origin: origin, size: size), display: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }

        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    /// Changes height keeping the bottom edge (the dock row) in place.
    func setHeight(_ height: CGFloat) {
        guard isVisible, let vf = screen?.visibleFrame else { return }
        var f = frame
        f.size.height = min(height, vf.maxY - f.minY)
        setFrame(f, display: true)
    }

    /// Changes size around the current center, staying on screen.
    func resize(to size: NSSize) {
        guard isVisible, let vf = screen?.visibleFrame else { return }
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    func dismiss() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

/// Hosting view that turns right-click / ctrl-click into a context menu.
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    var menuForEvent: (NSEvent) -> NSMenu? = { _ in nil }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuForEvent(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menuForEvent(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

final class DockController {
    private let panel = DockPanel()
    private let state = DockState()

    var isVisible: Bool { panel.isVisible }

    init() {
        let host = MenuHostingView(rootView: DockView(state: state))
        host.menuForEvent = { [weak self] _ in
            guard let self, let i = self.state.hoveredIndex, self.state.items.indices.contains(i) else { return nil }
            return self.menu(for: self.state.items[i])
        }
        panel.contentView = host
        state.onOpen = { [weak self] item in self?.activate(item) }
        state.onOpenApp = { [weak self] item in self?.open(item) }
        state.onSelectTab = { [weak self] tab in
            self?.hide()
            Tabs.select(tab)
        }
        state.onCloseTab = { [weak self] tab in self?.closeTab(tab) }
        state.onOpenProfile = { [weak self] profile in
            self?.hide()
            ChromeProfiles.open(profile)
        }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        // Keep running dots / recent apps live while the popup is open.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                self.state.sections = DockModel.load()
            }
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    private var baseHeight: CGFloat = 0

    func show() {
        state.stack = nil
        state.metrics = DockMetrics.current()
        state.sections = DockModel.load()
        state.hoverX = nil
        state.selected = nil

        let m = state.metrics
        let extra = m.magnify ? m.tileSize * (m.maxScale - 1) * 2.2 : 0
        let size = NSSize(width: state.baseRowWidth + m.padding * 2 + extra + 120,
                          height: m.tileSize * m.maxScale + m.padding * 2 + 6 + m.labelHeight)
        baseHeight = size.height
        // Cursor sits on the middle of the dock row.
        panel.present(size: size, anchorY: (m.tileSize + m.padding * 2 + 6) / 2)
    }

    func hide() {
        panel.dismiss()
    }

    // MARK: Tab stacks (Chrome, iTerm2)

    /// Click on an icon: tab-capable apps open their tab list, everything else opens.
    private func activate(_ item: DockItem) {
        guard item.isRunning, item.automation == nil, let app = item.bundleID.flatMap(TabApp.init(rawValue:)) else {
            open(item)
            return
        }
        if state.stack?.item.id == item.id {
            setStack(nil)
            return
        }
        let cached = Tabs.cached.filter { $0.app == app }
        state.stackHovered = nil
        state.stackSelected = cached.flatMap(\.tabs).first { $0.isCurrent }?.id
        let profiles = app == .chrome ? ChromeProfiles.closed() : []
        setStack(cached.isEmpty ? nil : DockStack(item: item, windows: cached, profiles: profiles))
        refreshStack(item, app: app, openIfEmpty: true)
    }

    private func refreshStack(_ item: DockItem, app: TabApp, openIfEmpty: Bool = false, after delay: TimeInterval = 0) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let fresh = await Tabs.fetch(app)
            Tabs.cached = Tabs.cached.filter { $0.app != app } + fresh
            guard let self, self.panel.isVisible else { return }
            let profiles = app == .chrome ? ChromeProfiles.closed() : []
            if fresh.isEmpty && profiles.isEmpty {
                // No windows, or no Automation permission yet: behave like a normal click.
                if openIfEmpty { self.open(item) } else { self.setStack(nil) }
                return
            }
            guard self.state.stack == nil || self.state.stack?.item.id == item.id else { return }
            if self.state.stack == nil && !openIfEmpty { return }
            self.setStack(DockStack(item: item, windows: fresh, profiles: profiles))
            if let sel = self.state.stackSelected, !fresh.flatMap(\.tabs).contains(where: { $0.id == sel }) {
                self.state.stackSelected = fresh.flatMap(\.tabs).first { $0.isCurrent }?.id
            }
        }
    }

    private func setStack(_ stack: DockStack?) {
        let m = state.metrics
        if let stack {
            let needed = m.rowHeight + m.stackGap + m.stackHeight(stack) + 8
            panel.setHeight(max(baseHeight, needed))
        }
        withAnimation(.easeOut(duration: 0.15)) { state.stack = stack }
        if stack == nil { panel.setHeight(baseHeight) }
    }

    private func closeTab(_ tab: TabInfo) {
        guard var stack = state.stack else { return }
        Tabs.close(tab)
        let tabs = stack.tabs
        let i = tabs.firstIndex { $0.id == tab.id } ?? 0
        for w in stack.windows.indices { stack.windows[w].tabs.removeAll { $0.id == tab.id } }
        stack.windows.removeAll { $0.tabs.isEmpty }
        state.stackHovered = nil
        let rest = stack.tabs
        state.stackSelected = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        setStack(rest.isEmpty ? nil : stack)
        refreshStack(stack.item, app: tab.app, after: 0.6)
    }

    private func handleStackKey(_ event: NSEvent, _ stack: DockStack) -> Bool {
        let current = stack.tabs.first { $0.id == (state.stackSelected ?? state.stackHovered) }
        if event.modifierFlags.contains(.command) {
            guard event.keyCode == 13, let current else { return false }      // ⌘W
            closeTab(current)
            return true
        }
        switch Int(event.keyCode) {
        case 53: setStack(nil)                                                // Esc
        case 126, 33: state.moveInStack(-1)                                   // ↑, [
        case 125, 30, 48: state.moveInStack(1)                                // ↓, ], Tab
        case 36, 76: if let current { state.onSelectTab(current) }            // Return
        case let code where numberRowKeys[code] != nil:                       // 1…9, 0
            let i = numberRowKeys[code]!
            if stack.tabs.indices.contains(i) { state.onSelectTab(stack.tabs[i]) }
        default:
            setStack(nil)                                                     // ← → etc. go back to the dock
            return handleKey(event)
        }
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let stack = state.stack { return handleStackKey(event, stack) }
        switch Int(event.keyCode) {
        case 53: hide()                                    // Esc
        case 123: state.move(-1)                           // ←
        case 124, 48: state.move(1)                        // →, Tab
        case 36, 76:                                       // Return, Enter
            if let i = state.selected, state.items.indices.contains(i) { open(state.items[i]) }
        default: return false
        }
        return true
    }

    // MARK: Context menu (mirrors the real Dock's)

    private func menu(for item: DockItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let showInFinder = ActionItem("Show in Finder") { [weak self] in
            self?.hide()
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }

        switch item.kind {
        case .app:
            let options = NSMenu()
            options.addItem(showInFinder)
            let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
            optionsItem.submenu = options
            menu.addItem(optionsItem)
            menu.addItem(.separator())

            let running = item.bundleID.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            }
            if let app = running {
                menu.addItem(ActionItem("Show All Windows") { [weak self] in self?.open(item) })
                menu.addItem(ActionItem(app.isHidden ? "Unhide" : "Hide") { [weak self] in
                    self?.hide()
                    if app.isHidden { app.unhide() } else { app.hide() }
                })
                if item.bundleID != "com.apple.finder" {
                    menu.addItem(ActionItem("Quit") { app.terminate() })
                    // Hold ⌥ to swap Quit for Force Quit, like the Dock.
                    let force = ActionItem("Force Quit", modifiers: .option) { app.forceTerminate() }
                    force.isAlternate = true
                    menu.addItem(force)
                }
            } else {
                menu.addItem(ActionItem("Open") { [weak self] in self?.open(item) })
            }

        case .folder:
            menu.addItem(ActionItem("Open \"\(item.name)\"") { [weak self] in self?.open(item) })
            menu.addItem(showInFinder)

        case .trash:
            menu.addItem(ActionItem("Open") { [weak self] in self?.open(item) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Empty Trash") { [weak self] in self?.emptyTrash() })
        }
        return menu
    }

    /// Opening ~/.Trash as a plain folder can show it empty (its contents are
    /// privacy-protected); Finder's own Trash window lists every volume's trash.
    private func openTrash() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\"\nactivate\nopen trash\nend tell")?.executeAndReturnError(&error)
        if error != nil { NSWorkspace.shared.open(DockModel.trashURL) }
    }

    private func emptyTrash() {
        hide()
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Let Finder do it so Trash on every volume is emptied.
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error { NSLog("Nav: empty trash failed: \(error)") }
    }

    private func open(_ item: DockItem) {
        hide()
        switch item.kind {
        case .app:
            if let pid = item.pid, let app = NSRunningApplication(processIdentifier: pid) {
                app.unhide()
                app.activate()
                return
            }
            if let id = item.bundleID,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                   .first(where: { !ProcessInfo.isAutomated($0.processIdentifier) }) {
                app.unhide()
                app.activate()
                // Reopen (like a Dock click) so apps with no windows show one.
                NSWorkspace.shared.openApplication(at: item.url, configuration: .init())
            } else {
                NSWorkspace.shared.openApplication(at: item.url, configuration: .init())
            }
        case .folder:
            NSWorkspace.shared.open(item.url)
        case .trash:
            openTrash()
        }
    }
}
