import AppKit
import SwiftUI

/// Edits ~/.config/nav/config.json. Every change is saved immediately and shown
/// live in the preview at the top.
final class SettingsModel: ObservableObject {
    @Published var config = Config.current {
        didSet {
            config.save()
            if config.launchAtLogin != oldValue.launchAtLogin { LoginItem.sync(config.launchAtLogin) }
            if config.hideDock != oldValue.hideDock, config.hideDock != MacDock.isHidden { MacDock.setHidden(config.hideDock) }
            if config.commandTab != oldValue.commandTab { updateHotKeysForFrontmostApp() }
            if config.shortcuts != oldValue.shortcuts { registerHotKeys() }
            if config.appStrip.extra != oldValue.appStrip.extra { refreshStripApps() }
        }
    }
    /// What can go in the ⌘E apps strip (the dock's tiles, then added apps), listed with a switch each.
    @Published private(set) var stripApps: [DockItem] = []

    func refreshStripApps() {
        // Playwright / Puppeteer instances come and go, so they can't be switched off by id.
        stripApps = AppStrip.candidates(config.appStrip).filter { $0.automation == nil }
    }

    func isInStrip(_ item: DockItem) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.config.appStrip.hidden.contains(item.id) != true },
                set: { [weak self] on in
                    guard let self else { return }
                    self.config.appStrip.hidden.removeAll { $0 == item.id }
                    if !on { self.config.appStrip.hidden.append(item.id) }
                })
    }

    func isAddedToStrip(_ item: DockItem) -> Bool { config.appStrip.extra.contains(item.id) }

    /// "Add app…": any app, after the dock's.
    func addStripApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path).filter { path in !stripApps.contains { $0.id == path } }
        config.appStrip.extra += paths
        config.appStrip.hidden.removeAll { panel.urls.map(\.path).contains($0) }
    }

    func removeFromStrip(_ item: DockItem) {
        config.appStrip.extra.removeAll { $0 == item.id }
        config.appStrip.hidden.removeAll { $0 == item.id }
    }
    /// The pane shown in the sidebar.
    /// The pane shown in the sidebar; Settings opens on the last one.
    @Published var pane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .general {
        didSet {
            guard pane != oldValue else { return }
            stopRecording()
            UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        }
    }
    /// Border opacity in the preview, so the fade can be replayed.
    @Published var previewOpacity: Double?
    private var playGeneration = 0

    var useAccent: Bool {
        get { config.popupBorder.color.lowercased() == "accent" }
        set { config.popupBorder.color = newValue ? "accent" : NSColor.controlAccentColor.hexString }
    }

    var color: Color {
        get { Color(nsColor: config.popupBorder.nsColor) }
        set { config.popupBorder.color = NSColor(newValue).hexString }
    }

    /// The shortcut being recorded in Settings, if any.
    @Published private(set) var recording: NavAction?
    private var recordMonitor: Any?

    /// Records the next key press as `action`'s shortcut. Nav's shortcuts are paused meanwhile,
    /// so pressing one that's taken records it instead of running it.
    func record(_ action: NavAction) {
        stopRecording()
        recording = action
        hotKeysSuspended = true
        updateHotKeysForFrontmostApp()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let plain = event.modifierFlags.isDisjoint(with: [.control, .option, .shift, .command])
            if plain && event.keyCode == 53 {                     // Esc
                self.stopRecording()
            } else if plain && event.keyCode == 51 {              // ⌫
                self.setShortcut(action, nil)
                self.stopRecording()
            } else if let shortcut = Shortcut(event: event) {
                self.setShortcut(action, shortcut)
                self.stopRecording()
            } else {
                NSSound.beep()                                    // needs a modifier
            }
            return nil
        }
    }

    func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        guard recording != nil else { return }
        recording = nil
        hotKeysSuspended = false
        updateHotKeysForFrontmostApp()
    }

    /// Gives `action` the shortcut, taking it off any other action; the default is stored as no override.
    func setShortcut(_ action: NavAction, _ shortcut: Shortcut?) {
        var shortcuts = config.shortcuts
        if let shortcut {
            for other in NavAction.allCases where other != action && config.shortcut(other) == shortcut {
                shortcuts[other.rawValue] = ""
            }
        }
        let value = shortcut?.string ?? ""
        shortcuts[action.rawValue] = value == Shortcut(action.defaultShortcut)?.string ? nil : value
        config.shortcuts = shortcuts
    }

    /// Puts `bundleID` on ⌥(i+1) ("" = most used), taking it off any other key.
    func setAppKey(_ i: Int, _ bundleID: String) {
        var keys = (config.appKeys + Array(repeating: "", count: AppUsage.keyCount)).prefix(AppUsage.keyCount)
            .map { $0 == bundleID ? "" : $0 }
        keys[i] = bundleID
        while keys.last == "" { keys.removeLast() }
        config.appKeys = keys
    }

    /// Apps to offer for ⌥1…⌥4: the running ones and those already picked, by name.
    var appChoices: [(id: String, name: String, icon: NSImage)] {
        var ids = Set(config.appKeys.filter { !$0.isEmpty })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { ids.insert(id) }
        }
        return ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return (id, AppUsage.name(of: id), icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Other…": pick any app from /Applications for ⌥(i+1).
    func chooseApp(for i: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use for ⌥\(i + 1)"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        setAppKey(i, id)
    }

    /// Replays fade in → hold → fade out, like when the popup opens.
    func play() {
        let b = config.popupBorder
        playGeneration += 1
        let gen = playGeneration
        previewOpacity = 0
        withAnimation(.easeOut(duration: b.fadeIn)) { previewOpacity = b.opacity }
        guard b.fade else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + b.fadeIn + b.duration) { [self] in
            guard gen == playGeneration else { return }
            withAnimation(.easeInOut(duration: b.fadeOut)) { previewOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + b.fadeOut + 0.8) { [self] in
                if gen == playGeneration { withAnimation { previewOpacity = nil } }
            }
        }
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        model.config = Config.current   // pick up hand edits to the file
        model.refreshStripApps()
        if let saved = UserDefaults.standard.string(forKey: "settingsPane").flatMap(SettingsPane.init(rawValue:)) {
            model.pane = saved
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Nav Settings"
            // The traffic lights sit inside the sidebar, like System Settings.
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            // An empty unified toolbar lowers the traffic lights into the sidebar's corner.
            w.toolbar = NSToolbar()
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(model: model))
            host.sizingOptions = []
            w.contentView = host
            w.setContentSize(NSSize(width: 800, height: 600))
            w.center()
            // Closing mid-recording would leave Nav's shortcuts paused.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) {
                [model] _ in model.stopRecording()
            }
            window = w
        }
        // Nav is a background app; plain activate() is refused when another app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// ⌘Tab shows Nav's windows view (true) or the macOS app switcher; saved and applied now.
    func setCommandTab(_ on: Bool) {
        model.config = Config.current
        model.config.commandTab = on
    }
}

enum SettingsPane: String, CaseIterable {
    case general, windows, dock, shortcuts, border

    var title: String {
        switch self {
        case .general: "General"
        case .windows: "Windows view"
        case .dock: "Dock"
        case .shortcuts: "Shortcuts"
        case .border: "Popup border"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, the macOS Dock and remote desktops."
        case .windows: "The window switcher with live previews."
        case .dock: "The Dock that pops up next to the cursor."
        case .shortcuts: "Global shortcuts and the four app keys."
        case .border: "The line around the ⌘⇧E popup."
        }
    }

    /// The pane's shortcut, shown in the sidebar.
    func hint(_ config: Config) -> String {
        switch self {
        case .windows: config.shortcut(.windows)?.label ?? ""
        case .dock: config.shortcut(.dock)?.label ?? ""
        default: ""
        }
    }
}

/// Colors of the Settings window, for Light and Dark.
struct SettingsTheme {
    let dark: Bool

    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 1)

    private func c(_ light: Color, _ dark: Color) -> Color { self.dark ? dark : light }
    private static func white(_ a: Double) -> Color { Color.white.opacity(a) }
    private static func black(_ a: Double) -> Color { Color.black.opacity(a) }
    private static func gray(_ a: Double) -> Color { Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(a) }
    private static func light(_ a: Double) -> Color { Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(a) }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255).opacity(a)
    }

    var fg: Color { c(Self.rgb(29, 29, 31), .white) }
    var win: Color { c(Self.rgb(247, 247, 249, 0.96), Self.rgb(28, 28, 32, 0.94)) }
    var side: Color { c(Self.black(0.035), Self.white(0.045)) }
    var line: Color { c(Self.black(0.08), Self.white(0.1)) }
    var card: Color { c(.white, Self.white(0.05)) }
    var cardRing: Color { c(Self.black(0.07), Self.white(0.06)) }
    var cardShadow: Color { c(Self.black(0.04), .clear) }
    var sep: Color { c(Self.black(0.07), Self.white(0.07)) }
    var fill: Color { c(Self.black(0.05), Self.white(0.07)) }
    var cap: Color { c(.white, Self.white(0.1)) }
    var capRing: Color { c(Self.black(0.18), Self.white(0.12)) }
    var fg2: Color { c(Self.gray(0.85), Self.light(0.85)) }
    var sec: Color { c(Self.gray(0.6), Self.light(0.55)) }
    var ter: Color { c(Self.gray(0.45), Self.light(0.4)) }
    var stage: Color { c(Self.rgb(211, 216, 226), Self.rgb(58, 63, 82)) }
    var bar: Color { c(Self.white(0.9), Self.white(0.28)) }
    var pcard: Color { c(Self.white(0.88), Self.rgb(30, 30, 34, 0.85)) }
    var overlay: Color { c(Self.white(0.7), Self.black(0.35)) }
    var switchOff: Color { c(Self.black(0.12), Self.white(0.16)) }
    var selectedRow: Color { c(Self.black(0.08), Self.white(0.1)) }
    var unselectedText: Color { c(Self.rgb(29, 29, 31), Self.light(0.7)) }
    var segOn: Color { c(.white, Self.white(0.16)) }
    var segOffText: Color { c(Self.rgb(29, 29, 31), Self.light(0.6)) }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    private var t: SettingsTheme { SettingsTheme(dark: scheme == .dark) }
    private var border: Config.BorderConfig { model.config.popupBorder }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.pane.title).font(.system(size: 24, weight: .bold)).kerning(-0.5)
                    Text(model.pane.subtitle).font(.system(size: 13)).foregroundStyle(t.sec)
                }
                .padding(.top, 30).padding(.horizontal, 28).padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { pane }
                        .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 13))
        .foregroundStyle(t.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.win)
        .ignoresSafeArea()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                let selected = model.pane == pane
                HStack(spacing: 8) {
                    Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    Text(pane.hint(model.config)).font(.system(size: 11)).monospacedDigit().foregroundStyle(t.ter)
                }
                .foregroundStyle(selected ? t.fg : t.unselectedText)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? t.selectedRow : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.pane = pane }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                sidebarButton("config.json", fill: t.fill, text: t.fg2) { NSWorkspace.shared.open(Config.url) }
                sidebarButton("Quit Nav", fill: Color(red: 1, green: 69 / 255, blue: 58 / 255).opacity(0.14),
                              text: Color(red: 1, green: 105 / 255, blue: 97 / 255)) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 2)
        }
        .padding(.top, 46).padding(.horizontal, 8).padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(t.side))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(t.line, lineWidth: 0.5))
        .padding(10)
        .frame(width: 216)
    }

    private func sidebarButton(_ title: String, fill: Color, text: Color, _ action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    // MARK: Panes

    @ViewBuilder private var pane: some View {
        switch model.pane {
        case .general: general
        case .windows: windowsPane
        case .dock: dockPane
        case .shortcuts: shortcutsPane
        case .border: borderPane
        }
    }

    private var general: some View {
        card {
            row { Text("Open Nav at login").font(.system(size: 13.5)) } trailing: { toggle($model.config.launchAtLogin) }
            separator
            row { described("Hide the macOS Dock", "Hidden while Nav runs (use ⌘E instead); it comes back when you quit Nav.") }
                trailing: { toggle($model.config.hideDock) }
            separator
            row { described("Pass ⌘E / ⌘⇧E to remote desktops",
                            "While Screen Sharing, Remote Desktop, VNC or a VM is in front, the shortcuts go to the remote Mac.") }
                trailing: { toggle($model.config.passShortcutsToRemoteApps) }
        }
    }

    private var windowsPane: some View {
        VStack(spacing: 22) {
            card {
                row(vertical: 12) { Text("Theme").font(.system(size: 13.5)) } trailing: {
                    segmented($model.config.theme, [("Modern", "modern"), ("Classic", "classic")])
                }
                separator
                row { Text("Preview on hover").font(.system(size: 13.5)) } trailing: { toggle($model.config.hoverPreview) }
                    .opacity(model.config.isModern ? 1 : 0.4)
                separator
                row(vertical: 12) { Text("Chrome profiles").font(.system(size: 13.5)) } trailing: {
                    segmented($model.config.chromeProfiles, [("Left", "left"), ("Right", "right"), ("Off", "off")])
                }
            }
            card {
                row {
                    described("⌘Tab switcher", model.config.commandTab
                              ? "⌘Tab / ⌘⇧Tab show Nav's windows view; ⌘⇧E shows the macOS app switcher."
                              : "⌘Tab is the macOS app switcher; ⌘⇧E shows Nav's windows view.")
                } trailing: { segmented($model.config.commandTab, [("Nav", true), ("macOS", false)]) }
            }
            appStripSettings
        }
    }

    /// The ⌘E apps strip in the windows view: on/off, side, size, names, and which apps.
    private var appStripSettings: some View {
        let strip = model.config.appStrip
        return VStack(alignment: .leading, spacing: 10) {
            header("⌘E APPS")
            card {
                row {
                    described("Show the ⌘E apps", "A strip of the dock's apps inside the windows view (⌘Tab); click one to open it.")
                } trailing: { toggle($model.config.appStrip.enabled) }
                Group {
                    separator
                    row(vertical: 12) { Text("Position").font(.system(size: 13.5)) } trailing: {
                        segmented($model.config.appStrip.position, AppStripPosition.allCases.map { ($0.title, $0.rawValue) })
                    }
                    separator
                    slider("Icon size", $model.config.appStrip.iconSize, 20...72, step: 2, unit: "pt")
                    separator
                    row { Text("Names under the icons").font(.system(size: 13.5)) } trailing: { toggle($model.config.appStrip.names) }
                }
                .opacity(strip.enabled ? 1 : 0.4)
                .allowsHitTesting(strip.enabled)
            }
            card {
                ForEach(Array(model.stripApps.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { separator }
                    row(vertical: 7) {
                        HStack(spacing: 10) {
                            Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: 22, height: 22)
                            Text(item.name).font(.system(size: 13.5)).lineLimit(1)
                            if model.isAddedToStrip(item) {
                                Text("Added").font(.system(size: 11)).foregroundStyle(t.sec)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(t.fill))
                            }
                        }
                    } trailing: {
                        HStack(spacing: 12) {
                            if model.isAddedToStrip(item) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 15)).foregroundStyle(t.ter)
                                    .contentShape(Circle())
                                    .onTapGesture { model.removeFromStrip(item) }
                                    .help("Remove from the strip")
                            }
                            toggle(model.isInStrip(item))
                        }
                    }
                }
                separator
                row(vertical: 10) {
                    Text("The ⌘E dock's apps, then the ones you add. Running apps change as you open and quit them.")
                        .font(.system(size: 12)).foregroundStyle(t.sec).fixedSize(horizontal: false, vertical: true)
                } trailing: { pill("Add app…") { model.addStripApp() } }
            }
            .opacity(strip.enabled ? 1 : 0.4)
            .allowsHitTesting(strip.enabled)
        }
    }

    private var dockPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(DockPlacement.allCases, id: \.self) { placement in
                    dockOption(placement)
                }
            }
            Text(model.config.dockPlacement == .free
                 ? "Opens where the mouse is."
                 : "Stuck to the \(model.config.dockPosition) edge of the screen the mouse is on.")
                .font(.system(size: 12)).foregroundStyle(t.sec).padding(.horizontal, 4)
        }
    }

    private func dockOption(_ placement: DockPlacement) -> some View {
        let selected = model.config.dockPlacement == placement
        // Where the dock sits on the little screen: x, y, width, height as fractions.
        let shape: (CGFloat, CGFloat, CGFloat, CGFloat) = switch placement {
        case .free: (0.38, 0.42, 0.34, 0.14)
        case .left: (0.04, 0.20, 0.09, 0.60)
        case .bottom: (0.20, 0.80, 0.60, 0.13)
        case .right: (0.87, 0.20, 0.09, 0.60)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(t.bar)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.line, lineWidth: 0.5))
                            .frame(width: geo.size.width * shape.2, height: geo.size.height * shape.3)
                            .offset(x: geo.size.width * shape.0, y: geo.size.height * shape.1)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.stage))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(placement.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? SettingsTheme.accent : t.cardRing, lineWidth: selected ? 2 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { model.config.dockPosition = placement.rawValue }
    }

    private var shortcutsPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            card {
                ForEach(Array([NavAction.windows, .dock, .claude, .switchTopTwo].enumerated()), id: \.offset) { i, action in
                    if i > 0 { separator }
                    row(vertical: 11) { Text(action.title).font(.system(size: 13.5)) } trailing: {
                        HStack(spacing: 6) {
                            resetButton(action)
                            keyCaps(action)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                header("APP KEYS")
                card {
                    let choices = model.appChoices
                    ForEach(0..<AppUsage.keyCount, id: \.self) { i in
                        if i > 0 { separator }
                        row(vertical: 10) {
                            HStack(spacing: 6) {
                                keyCaps(NavAction.appKeys[i])
                                resetButton(NavAction.appKeys[i])
                            }
                        } trailing: { appMenu(i, choices) }
                    }
                }
                note("Work from any app (and 1…4 in the windows view); an app that isn't running is opened. \"Most used\" keys follow the apps you switch to most.")
            }
            Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ turns it off, ↺ puts back the default.")
                .font(.system(size: 12)).foregroundStyle(t.ter).padding(.horizontal, 4)
        }
    }

    private var borderPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            borderStage
            VStack(alignment: .leading, spacing: 22) {
                card {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        swatch("solid", "Solid", AnyShapeStyle(Color(nsColor: border.nsColor)))
                        ForEach(BorderPalette.all) { p in
                            swatch(p.id, p.name, AnyShapeStyle(LinearGradient(colors: p.colors.map { Color(nsColor: $0) },
                                                                              startPoint: .leading, endPoint: .trailing)))
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 14)
                    separator
                    if border.palette == "solid" {
                        row { Text("Use the system accent color").font(.system(size: 13.5)) } trailing: {
                            toggle(Binding(get: { model.useAccent }, set: { model.useAccent = $0 }))
                        }
                        if !model.useAccent {
                            separator
                            row(vertical: 10) { Text("Color").font(.system(size: 13.5)) } trailing: {
                                ColorPicker("", selection: Binding(get: { model.color }, set: { model.color = $0 }),
                                            supportsOpacity: true)
                                    .labelsHidden()
                            }
                        }
                    } else {
                        row { Text("Rotate the colors").font(.system(size: 13.5)) } trailing: {
                            toggle($model.config.popupBorder.animate)
                        }
                    }
                }
                card {
                    slider("Width", $model.config.popupBorder.width, 1...20, step: 1, unit: "pt")
                    separator
                    slider("Corner radius", $model.config.popupBorder.cornerRadius, 0...40, step: 1, unit: "pt")
                    separator
                    slider("Outset", $model.config.popupBorder.outset, -10...20, step: 1, unit: "pt")
                    separator
                    slider("Glow", $model.config.popupBorder.glow, 0...40, step: 1, unit: "pt")
                    separator
                    slider("Opacity", $model.config.popupBorder.opacity, 0.1...1, step: 0.05, unit: "")
                }
                VStack(alignment: .leading, spacing: 8) {
                    header("TIMING")
                    card {
                        row { Text("Fade out").font(.system(size: 13.5)) } trailing: { toggle($model.config.popupBorder.fade) }
                        separator
                        slider("Visible for", $model.config.popupBorder.duration, 0.5...10, step: 0.5, unit: "s")
                            .opacity(border.fade ? 1 : 0.4).disabled(!border.fade)
                        separator
                        slider("Fade in", $model.config.popupBorder.fadeIn, 0...1, step: 0.05, unit: "s")
                        separator
                        slider("Fade out", $model.config.popupBorder.fadeOut, 0...3, step: 0.1, unit: "s")
                            .opacity(border.fade ? 1 : 0.4).disabled(!border.fade)
                    }
                }
            }
            .opacity(border.enabled ? 1 : 0.4)
            .disabled(!border.enabled)
            pill("Reset border") { model.config.popupBorder = .init() }
        }
    }

    /// A mini popup wearing the border exactly as configured, with the on/off switch and Play fade.
    private var borderStage: some View {
        let b = border
        let radius = CGFloat(b.cornerRadius)
        return ZStack {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(["GTM Console · gtm.nstarxinc.com", "Call Floor UX improvement · claude.ai",
                               "Navigator macOS cu cmd+e"].enumerated()), id: \.offset) { i, title in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(t.sec)
                        Text(title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .frame(width: 270)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(t.pcard)
                .shadow(color: .black.opacity(t.dark ? 0.35 : 0.15), radius: 15, y: 10))
            .overlay {
                if b.enabled {
                    PopupBorder(config: b)
                        .opacity(model.previewOpacity ?? b.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.stage))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Text("Border").font(.system(size: 12))
                toggle($model.config.popupBorder.enabled)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
            .background(Capsule().fill(t.overlay))
            .overlay(Capsule().strokeBorder(t.line, lineWidth: 0.5))
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("▶ Play fade")
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(t.overlay))
                .overlay(Capsule().strokeBorder(t.line, lineWidth: 0.5))
                .contentShape(Capsule())
                .onTapGesture { if b.enabled { model.play() } }
                .opacity(b.enabled ? 1 : 0.4)
                .padding(12)
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.card)
                .shadow(color: t.cardShadow, radius: 1, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.cardRing, lineWidth: 0.5))
    }

    private func row<L: View, R: View>(vertical: CGFloat = 14, @ViewBuilder _ leading: () -> L,
                                       @ViewBuilder trailing: () -> R) -> some View {
        HStack(spacing: 20) {
            leading()
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, vertical)
    }

    private var separator: some View { Rectangle().fill(t.sep).frame(height: 0.5) }

    private func described(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5))
            Text(detail).font(.system(size: 12)).foregroundStyle(t.sec).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).kerning(0.24).foregroundStyle(t.sec).padding(.horizontal, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(t.sec).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12)).foregroundStyle(t.fg2)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(t.fill))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        let on = isOn.wrappedValue
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? SettingsTheme.accent : t.switchOff)
            Circle().fill(.white).frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                .padding(2)
        }
        .frame(width: 40, height: 24)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { isOn.wrappedValue.toggle() } }
    }

    private func segmented<V: Hashable>(_ selection: Binding<V>, _ options: [(String, V)]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection.wrappedValue == option.1
                Text(option.0)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? t.fg : t.segOffText)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(Capsule().fill(selected ? t.segOn : .clear)
                        .shadow(color: .black.opacity(selected ? (t.dark ? 0.3 : 0.2) : 0), radius: 1, y: 0.5))
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = option.1 } }
            }
        }
        .padding(3)
        .background(Capsule().fill(t.fill))
        .fixedSize()
    }

    /// The shortcut as keycaps: click, then press the new keys (Esc cancels, ⌫ turns it off).
    private func keyCaps(_ action: NavAction) -> some View {
        let recording = model.recording == action
        let caps = recording ? ["Press keys…"] : (model.config.shortcut(action)?.caps ?? ["Off"])
        return HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.cap)
                        .shadow(color: .black.opacity(t.dark ? 0 : 0.06), radius: 0.5, y: 1))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(t.capRing, lineWidth: 0.5))
                    .overlay(alignment: .bottom) {
                        // The keycap's lower lip.
                        Rectangle().fill(.black.opacity(t.dark ? 0.35 : 0.1)).frame(height: 1).padding(.horizontal, 3)
                    }
            }
        }
        .padding(3)
        .overlay {
            if recording {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(SettingsTheme.accent, lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SettingsTheme.accent.opacity(0.25), lineWidth: 3.5)
                    .padding(-3.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { recording ? model.stopRecording() : model.record(action) }
        .help("Click, then press the new keys")
    }

    private func resetButton(_ action: NavAction) -> some View {
        let changed = model.config.shortcuts[action.rawValue] != nil
        return Text("↺")
            .foregroundStyle(t.sec)
            .frame(width: 22)
            .contentShape(Rectangle())
            .onTapGesture { if changed { model.setShortcut(action, Shortcut(action.defaultShortcut)) } }
            .opacity(changed ? 1 : 0)
            .help("Back to \(Shortcut(action.defaultShortcut)?.label ?? "")")
    }

    private static let otherTag = "\u{0}other"

    /// The app (or Nav feature) on ⌥(i+1), as a pill that opens a menu.
    private func appMenu(_ i: Int, _ choices: [(id: String, name: String, icon: NSImage)]) -> some View {
        let current = model.config.appKeys.indices.contains(i) ? model.config.appKeys[i] : ""
        return Menu {
            Button("Most used") { model.setAppKey(i, "") }
            Divider()
            ForEach(choices, id: \.id) { app in
                Button { model.setAppKey(i, app.id) } label: { Label { Text(app.name) } icon: { Image(nsImage: app.icon) } }
            }
            Divider()
            ForEach(NavFeature.allCases, id: \.self) { feature in
                Button { model.setAppKey(i, feature.id) } label: { Label("Nav: \(feature.title)", systemImage: feature.symbol) }
            }
            Divider()
            Button("Other…") { DispatchQueue.main.async { model.chooseApp(for: i) } }
        } label: {
            HStack(spacing: 8) {
                Text(current.isEmpty ? "Most used" : (NavFeature(id: current).map { "Nav: \($0.title)" } ?? AppUsage.name(of: current)))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(t.sec)
            }
            .foregroundStyle(t.fg)
            .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 5)
            .frame(width: 190)
            .background(Capsule().fill(t.fill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
    }

    private func swatch(_ id: String, _ name: String, _ style: AnyShapeStyle) -> some View {
        let selected = border.palette.lowercased() == id
        return VStack(spacing: 7) {
            Circle().fill(style).frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Circle().strokeBorder(t.dark ? Color.white : Color.black.opacity(0.8), lineWidth: 2).padding(-4)
                    }
                }
            Text(name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? t.fg : t.sec)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.config.popupBorder.palette = id }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double, unit: String) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13.5)).frame(width: 96, alignment: .leading)
            // Stepped by rounding, not `step:`, which draws tick marks.
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = (($0 - range.lowerBound) / step).rounded() * step + range.lowerBound }),
                   in: range)
                .tint(SettingsTheme.accent).controlSize(.small)
            Text(step < 1 ? String(format: "%.2g%@", value.wrappedValue, unit) : "\(Int(value.wrappedValue))\(unit)")
                .font(.system(size: 12)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(minWidth: 44)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.fill))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

extension Config {
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Config.url, options: .atomic)
    }
}

extension NSColor {
    /// "#RRGGBB", or "#RRGGBBAA" when not fully opaque.
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#0A84FF" }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255)), a = Int(round(c.alphaComponent * 255))
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
