import AppKit
import SwiftUI

/// ⌘⇧E: previews of every open window, grouped by app.
final class WindowsController {
    private let panel = DockPanel()
    private let state = WindowsState()
    private var loadTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }

    init() {
        let host = MenuHostingView(rootView: SwitcherView(state: state))
        host.menuForEvent = { [weak self] _ in
            guard let self, let t = self.state.flat.first(where: { $0.id == self.state.hovered }) else { return nil }
            return self.menu(for: t)
        }
        panel.contentView = host
        state.onFocus = { [weak self] target in self?.focus(target) }
        state.onClose = { [weak self] target in self?.close(target) }
        state.onOpenProfile = { [weak self] profile in
            self?.hide()
            ChromeProfiles.open(profile)
        }
        state.onOpenSettings = { [weak self] in
            self?.hide()
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
        state.onOpenPreferences = { [weak self] in
            self?.hide()
            SettingsWindowController.shared.show()
        }
        state.onToggleCommandTab = { [weak self] in
            guard let self else { return }
            self.state.commandTab.toggle()
            SettingsWindowController.shared.setCommandTab(self.state.commandTab)
        }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        Task { @MainActor in Tabs.cached = await Tabs.fetchAll() }   // warm the cache for the first popup
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Next (1) / previous (-1) app, for ⌘Tab / ⌘⇧Tab pressed again while the view is open.
    func moveSelection(_ step: Int) {
        state.move(app: step)
    }

    func hide() {
        loadTask?.cancel()
        panel.dismiss()
    }

    func show() {
        let config = Config.current
        state.border = config.popupBorder
        state.modern = config.isModern
        state.hoverPreview = config.hoverPreview
        state.commandTab = config.commandTab
        state.peek.id = nil
        state.hovered = nil
        state.selected = nil

        guard WindowsModel.hasScreenRecording else {
            CGRequestScreenCaptureAccess()   // system prompt, first time only
            state.needsPermission = true
            state.groups = []
            let margin = state.border.margin * 2
            panel.present(size: NSSize(width: 420 + margin, height: 200 + margin), anchorY: 100 + margin / 2)
            startBorder()
            return
        }
        state.needsPermission = false

        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let freshTabs = Tabs.fetchAll()
            let groups = (try? await WindowsModel.load(tabs: Tabs.cached)) ?? []
            guard !Task.isCancelled else { return }
            self.state.groups = groups
            self.state.selected = self.state.flat.first?.id
            self.present()
            async let thumbnails: Void = self.loadThumbnails()

            let tabs = await freshTabs
            Tabs.cached = tabs
            if !Task.isCancelled {
                let selected = self.state.selected
                self.state.applyTabs(tabs)
                if !self.state.flat.contains(where: { $0.id == selected }) { self.state.selected = self.state.flat.first?.id }
                self.panel.resize(to: self.panelSize())
            }
            await thumbnails
        }
    }

    /// Re-reads windows after a close/quit, keeping thumbnails we already have.
    /// If `pending` is still there, its app is probably asking for confirmation
    /// ("Save changes?", "Close tab with running job?"), so step aside and show it.
    private func reload(after delay: TimeInterval, pending: SwitchTarget, wholeApp: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.panel.isVisible else { return }
            let tabs = await Tabs.fetchAll()
            Tabs.cached = tabs
            guard var groups = try? await WindowsModel.load(tabs: tabs), !Task.isCancelled else { return }
            let images = Dictionary(self.state.groups.flatMap(\.windows).compactMap { w in w.image.map { (w.id, $0) } },
                                    uniquingKeysWith: { a, _ in a })
            for g in groups.indices {
                for w in groups[g].windows.indices { groups[g].windows[w].image = images[groups[g].windows[w].id] }
            }
            let stillThere = groups.contains { g in
                wholeApp ? g.pid == pending.window.pid
                         : g.windows.contains { w in w.id == pending.window.id && (pending.tab == nil || !w.tabs.isEmpty) }
            }
            if stillThere && (wholeApp || pending.tab == nil || Tabs.hasTab(pending.tab!, in: tabs)) {
                self.focus(pending)
                return
            }
            let selected = self.state.selected
            self.state.groups = groups
            if !self.state.flat.contains(where: { $0.id == selected }) { self.state.selected = self.state.flat.first?.id }
            if groups.isEmpty { self.hide(); return }
            self.panel.resize(to: self.panelSize())
            await self.loadThumbnails(onlyMissing: true)
        }
    }

    private func present() {
        let size = panelSize()
        panel.present(size: size, anchorY: size.height / 2)
        startBorder()
    }

    private var borderGeneration = 0

    /// Fades the popup border in, then (optionally) out after the configured time.
    private func startBorder() {
        let cfg = state.border
        borderGeneration += 1
        let gen = borderGeneration
        state.borderOpacity = 0
        guard cfg.enabled else { return }
        withAnimation(.easeOut(duration: cfg.fadeIn)) { state.borderOpacity = cfg.opacity }
        guard cfg.fade else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.fadeIn + cfg.duration) { [weak self] in
            guard let self, gen == self.borderGeneration else { return }
            withAnimation(.easeInOut(duration: cfg.fadeOut)) { self.state.borderOpacity = 0 }
        }
    }

    private func panelSize() -> NSSize {
        let screen = panel.isVisible ? panel.screen
            : NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let vf = (screen ?? NSScreen.main!).visibleFrame
        let margin = state.border.margin * 2
        if state.modern {
            let content = ModernMetrics().contentSize(state, maxWidth: vf.width * 0.92)
            return NSSize(width: content.width + margin, height: min(content.height, vf.height * 0.85) + margin)
        }
        let content = state.metrics.contentSize(state.groups)
        return NSSize(width: min(content.width, vf.width * 0.92) + margin,
                      height: min(content.height, vf.height * 0.85) + margin)
    }

    private func loadThumbnails(onlyMissing: Bool = false) async {
        let m = state.metrics
        // Modern also previews tabbed windows (one-tab cards, the hover preview).
        let modern = state.modern
        let windows = state.groups.flatMap(\.windows)
            .filter { (modern || $0.tabs.isEmpty) && !(onlyMissing && $0.image != nil) }
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for w in windows {
                // Capture at 2x the card size for retina.
                let size = modern ? CGSize(width: 560, height: 350)
                                  : CGSize(width: m.cardWidth(w) * 2, height: m.thumbHeight * 2)
                group.addTask { (w.id, await WindowsModel.thumbnail(of: w, maxSize: size)) }
            }
            for await (id, image) in group {
                guard !Task.isCancelled else { return }
                if let image { await MainActor.run { state.setImage(image, for: id) } }
            }
        }
    }

    private func focus(_ target: SwitchTarget) {
        hide()
        AppUsage.record(target.window.bundleID)
        WindowsModel.requestAccessibilityIfNeeded()
        let bundleURL = state.appFor(target.window)?.bundleURL
        guard let tab = target.tab else {
            WindowsModel.focus(target.window, bundleURL: bundleURL)
            return
        }
        // Scripting picks the tab, but Chrome's `activate` doesn't reliably bring the
        // window above a zoomed window of another app, so raise it like a window click.
        Tabs.select(tab) { WindowsModel.focus(target.window, bundleURL: bundleURL) }
    }

    // MARK: Close / quit

    /// Closes a window (its close button) or an iTerm2 tab. The popup stays open.
    private func close(_ target: SwitchTarget) {
        if let tab = target.tab {
            Tabs.close(tab)
        } else if !WindowsModel.close(target.window) {
            // Closing another app's window needs Accessibility.
            WindowsModel.requestAccessibilityIfNeeded(force: true)
            return
        }
        state.remove(target.id)
        reload(after: 0.6, pending: target)
    }

    /// Moves the window (a tab's whole window) to another display and switches to it.
    private func move(_ target: SwitchTarget, to screen: NSScreen) {
        guard WindowsModel.move(target.window, to: screen) else {
            WindowsModel.requestAccessibilityIfNeeded(force: true)
            return
        }
        focus(target)
    }

    private func quit(_ target: SwitchTarget, force: Bool) {
        guard let app = NSRunningApplication(processIdentifier: target.window.pid) else { return }
        _ = force ? app.forceTerminate() : app.terminate()
        state.remove(pid: target.window.pid)
        reload(after: 1.0, pending: target, wholeApp: true)
    }

    private func menu(for target: SwitchTarget) -> NSMenu {
        let menu = NSMenu()
        let appName = state.appFor(target.window)?.name ?? "App"
        menu.addItem(ActionItem(target.tab == nil ? "Close Window" : "Close Tab", key: "w", modifiers: .command) { [weak self] in
            self?.close(target)
        })
        let displays = WindowsModel.displays
        if displays.count > 1 {
            menu.addItem(.separator())
            let current = WindowsModel.display(of: target.window)
            for (index, screen) in displays {
                let item = ActionItem("Move to Display \(index) — \(screen.localizedName)") { [weak self] in
                    self?.move(target, to: screen)
                }
                if screen == current {
                    item.state = .on
                    item.action = nil   // already there
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit \(appName)", key: "q", modifiers: .command) { [weak self] in
            self?.quit(target, force: false)
        })
        let force = ActionItem("Force Quit \(appName)", key: "q", modifiers: [.command, .option]) { [weak self] in
            self?.quit(target, force: true)
        }
        force.isAlternate = true
        menu.addItem(force)
        return menu
    }

    private var current: SwitchTarget? {
        let id = state.selected ?? state.hovered
        return state.flat.first { $0.id == id }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            switch Int(event.keyCode) {
            case 13: if let t = current { close(t) }                                   // ⌘W
            case 12: if let t = current { quit(t, force: mods.contains(.option)) }     // ⌘Q, ⌥⌘Q
            case 43: state.onOpenPreferences()                                         // ⌘,
            case let code where (numberRowKeys[code] ?? 9) < state.frequent.count:      // ⌘1…⌘4: most used apps
                if let t = state.target(forKey: numberRowKeys[code]!) { focus(t) }
            default: return false
            }
            return true
        }
        if state.modern, let handled = handleModernKey(event, mods: mods) { return handled }
        switch Int(event.keyCode) {
        case 53: hide()                                    // Esc
        case 123: state.move(horizontal: -1)               // ←
        case 124, 48, 30: state.move(horizontal: 1)        // →, Tab, ]
        case 33: state.move(horizontal: -1)                // [
        case 126: state.move(vertical: -1)                 // ↑
        case 125: state.move(vertical: 1)                  // ↓
        case 36, 76:                                       // Return, Enter
            if let t = current { focus(t) }
        case let code where numberRowKeys[code] != nil:    // 1…9, 0 → most used apps, then windows
            if let t = state.target(forKey: numberRowKeys[code]!) { focus(t) }
        default: return false
        }
        return true
    }

    /// Modern extras: ⌥1…9 opens a closed Chrome profile, A…Z switch like 1…0.
    private func handleModernKey(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> Bool? {
        if mods == .option, let i = numberRowKeys[Int(event.keyCode)] {
            let profiles = state.groups.first { !$0.chromeProfiles.isEmpty }?.chromeProfiles ?? []
            if profiles.indices.contains(i) { state.onOpenProfile(profiles[i]) }
            return true
        }
        guard mods.isDisjoint(with: [.control, .option]),
              let key = event.charactersIgnoringModifiers?.uppercased(), key.count == 1,
              let i = WindowsState.shortcutKeys.firstIndex(of: key), i >= 10 else { return nil }
        if let t = state.target(forKey: i) { focus(t) }
        return true
    }
}

/// Physical number-row keys 1…9, 0 (layout independent) → item index.
let numberRowKeys: [Int: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9]
