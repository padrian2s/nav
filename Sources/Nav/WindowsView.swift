import SwiftUI

struct WindowsMetrics {
    let thumbHeight: CGFloat = 120
    let minCardWidth: CGFloat = 100
    let maxCardWidth: CGFloat = 220
    let titleHeight: CGFloat = 16
    let cardPadding: CGFloat = 6
    let spacing: CGFloat = 12
    let headerWidth: CGFloat = 84
    let padding: CGFloat = 18
    let footerHeight: CGFloat = 30
    let tabRowHeight: CGFloat = 22
    let tabCardWidth: CGFloat = 300
    let minRowHeight: CGFloat = 84     // app icon + name

    func cardWidth(_ w: WindowInfo) -> CGFloat {
        if !w.tabs.isEmpty { return tabCardWidth }
        let aspect = w.frame.height > 0 ? w.frame.width / w.frame.height : 1.6
        return min(max(thumbHeight * aspect, minCardWidth), maxCardWidth)
    }

    func cardHeight(_ w: WindowInfo) -> CGFloat {
        w.tabs.isEmpty ? thumbHeight + 6 + titleHeight : CGFloat(w.tabs.count) * tabRowHeight
    }

    func rowHeight(_ g: AppWindows) -> CGFloat {
        max((g.windows.map(cardHeight).max() ?? 0) + cardPadding * 2, minRowHeight)
    }

    func rowWidth(_ g: AppWindows) -> CGFloat {
        headerWidth + g.windows.reduce(0) { $0 + spacing + cardWidth($1) + cardPadding * 2 }
            + (g.chromeProfiles.isEmpty ? 0 : spacing + profilesCardWidth(g.chromeProfiles.count))
    }

    func profilesCardWidth(_ count: Int) -> CGFloat { CGFloat(count) * 72 + 16 }

    func contentSize(_ groups: [AppWindows]) -> CGSize {
        let width = (groups.map(rowWidth).max() ?? 320) + padding * 2
        let height = groups.map(rowHeight).reduce(0, +) + CGFloat(max(groups.count - 1, 0)) * spacing + padding * 2 + footerHeight
        return CGSize(width: max(width, 320), height: max(height, 120))
    }
}

final class WindowsState: ObservableObject {
    @Published var groups: [AppWindows] = []
    @Published var needsPermission = false
    @Published var border = Config.BorderConfig()
    @Published var borderOpacity: Double = 0
    @Published var hovered: String?          // SwitchTarget.id
    @Published var selected: String?
    /// Modern theme (see `ModernWindowsView`); set from the config on every show.
    @Published var modern = true
    /// Modern: show the window preview next to the mouse over list rows.
    var hoverPreview = true
    /// Modern: apps folded to a one-line summary (by `collapseKey`), kept across launches.
    @Published var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedApps") }
    }
    /// Modern: where the mouse is over a tab/window row, for the preview next to it.
    let peek = PeekState()
    let metrics = WindowsMetrics()
    var onFocus: (SwitchTarget) -> Void = { _ in }
    var onClose: (SwitchTarget) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}       // System Settings → Screen Recording
    var onOpenPreferences: () -> Void = {}    // Nav's own settings
    var onOpenProfile: (ChromeProfile) -> Void = { _ in }

    /// Everything selectable, in display order: each window, or each tab of an iTerm2 window.
    /// Modern shows one-window apps first and leaves collapsed apps out.
    var flat: [SwitchTarget] {
        guard modern else { return groups.flatMap(targets) }
        return singles.flatMap(targets) + multiGroups.filter { !isCollapsed($0) }.flatMap(targets)
    }

    func targets(_ g: AppWindows) -> [SwitchTarget] {
        g.windows.flatMap { w in
            w.tabs.isEmpty ? [SwitchTarget(window: w, tab: nil)] : w.tabs.map { SwitchTarget(window: w, tab: $0) }
        }
    }

    /// Modern: an app with a single window and at most one tab gets a card in the top row.
    func isSingle(_ g: AppWindows) -> Bool { g.windows.count == 1 && g.windows[0].tabs.count <= 1 && g.chromeProfiles.isEmpty }
    var singles: [AppWindows] { groups.filter(isSingle) }
    var multiGroups: [AppWindows] { groups.filter { !isSingle($0) } }

    func collapseKey(_ g: AppWindows) -> String {
        (g.bundleURL?.path ?? g.name) + (g.automation.map { "#\($0.name)" } ?? "")
    }

    func isCollapsed(_ g: AppWindows) -> Bool { collapsed.contains(collapseKey(g)) }

    func toggleCollapsed(_ g: AppWindows) {
        let index = flat.firstIndex { $0.id == (selected ?? hovered) } ?? 0
        let key = collapseKey(g)
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        let all = flat
        if !all.contains(where: { $0.id == selected }) {
            selected = all.isEmpty ? nil : all[min(index, all.count - 1)].id
        }
        hovered = nil
    }

    /// Shortcut keys: 1…9, 0, then (Modern) A…Z.
    static let shortcutKeys = Array("1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    /// Shortcut label: "1"…"9", then "0" for the 10th, then letters in Modern.
    func shortcut(for id: String) -> String? {
        guard let i = flat.firstIndex(where: { $0.id == id }), i < (modern ? Self.shortcutKeys.count : 10) else { return nil }
        return Self.shortcutKeys[i]
    }

    func setImage(_ image: NSImage, for id: CGWindowID) {
        for g in groups.indices {
            if let w = groups[g].windows.firstIndex(where: { $0.id == id }) {
                groups[g].windows[w].image = image
                return
            }
        }
    }

    func applyTabs(_ snapshot: [TabWindow]) {
        for g in groups.indices { Tabs.assign(to: &groups[g].windows, from: snapshot) }
    }

    /// Optimistically drops a closed window/tab (or a quit app) and keeps the
    /// selection at the same position.
    func remove(_ id: String? = nil, pid: pid_t? = nil) {
        let index = flat.firstIndex { $0.id == (selected ?? hovered) } ?? 0
        for g in groups.indices {
            if let pid, groups[g].pid == pid { groups[g].windows = [] }
            groups[g].windows = groups[g].windows.compactMap { window in
                var w = window
                if id == "w\(w.id)" { return nil }
                if let id, w.tabs.contains(where: { $0.id == id }) {
                    w.tabs.removeAll { $0.id == id }
                    if w.tabs.isEmpty { return nil }   // last tab closed → window is gone
                }
                return w
            }
        }
        groups.removeAll { $0.windows.isEmpty }
        hovered = nil
        let all = flat
        selected = all.isEmpty ? nil : all[min(index, all.count - 1)].id
    }

    func appFor(_ window: WindowInfo) -> AppWindows? {
        groups.first { $0.pid == window.pid }
    }

    /// ← → walk windows/tabs; ↑ ↓ jump between apps.
    func move(horizontal delta: Int) {
        let all = flat
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == (selected ?? hovered) } ?? (delta > 0 ? -1 : all.count)
        selected = all[(i + delta + all.count) % all.count].id
        hovered = nil
    }

    func move(vertical delta: Int) {
        if modern { return move(horizontal: delta) }   // one list, top to bottom
        guard !groups.isEmpty else { return }
        let pid = flat.first { $0.id == (selected ?? hovered) }?.window.pid
        let current = groups.firstIndex { $0.pid == pid }
        let g = current.map { ($0 + delta + groups.count) % groups.count } ?? (delta > 0 ? 0 : groups.count - 1)
        selected = flat.first { $0.window.pid == groups[g].pid }?.id
        hovered = nil
    }
}

struct WindowsView: View {
    @ObservedObject var state: WindowsState

    var body: some View {
        let m = state.metrics
        Group {
            if state.needsPermission {
                permissionPrompt
            } else if state.groups.isEmpty {
                Text("No open windows")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal], showsIndicators: false) {
                        VStack(alignment: .leading, spacing: m.spacing) {
                            ForEach(state.groups) { group in
                                row(group)
                            }
                        }
                        .padding(m.padding)
                    }
                    // Keep the keyboard selection visible.
                    .onChange(of: state.selected) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !state.needsPermission { footer }
        }
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(dockFrost))
                .glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        }
        .overlay {
            if state.border.enabled {
                PopupBorder(config: state.border)
                    .opacity(state.borderOpacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(state.border.margin)   // room for the line and glow outside the glass
    }

    private var radius: CGFloat { CGFloat(state.border.cornerRadius) }

    /// Shortcut hints and the settings button.
    private var footer: some View {
        HStack(spacing: 0) {
            Text("1–9 switch  ·  [ ] select  ·  ⌘W close  ·  ⌘Q quit")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Quit Nav (brings the Dock back)")
            Button { state.onOpenPreferences() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Nav Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .frame(height: state.metrics.footerHeight)
    }

    private func row(_ group: AppWindows) -> some View {
        let m = state.metrics
        return HStack(alignment: .top, spacing: m.spacing) {
            VStack(spacing: 4) {
                Image(nsImage: group.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .overlay(alignment: .bottomTrailing) {
                        if let kind = group.automation { AutomationBadge(kind: kind, size: 20).offset(x: 4, y: 4) }
                    }
                HStack(spacing: 3) {
                    if group.isAudible { AudioIcon(size: 9) }
                    Text(group.name)
                        .font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let kind = group.automation {
                    Text(kind.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: kind.color))
                }
            }
            .frame(width: m.headerWidth)
            .padding(.top, max((m.rowHeight(group) - m.minRowHeight) / 2, 0))

            if !group.chromeProfiles.isEmpty && Config.current.profilesOnLeft {
                profilesCard(group)
            }

            ForEach(group.windows) { window in
                if window.tabs.isEmpty {
                    card(window, icon: group.icon, appName: group.name)
                } else {
                    tabsCard(window)
                }
            }
            if !group.chromeProfiles.isEmpty && !Config.current.profilesOnLeft {
                profilesCard(group)
            }
        }
        .frame(height: m.rowHeight(group), alignment: .top)
    }

    /// Closed Chrome profiles; click one to open a window with it.
    private func profilesCard(_ group: AppWindows) -> some View {
        let m = state.metrics
        return VStack(alignment: .leading, spacing: 6) {
            Text("Open profile")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(group.chromeProfiles) { profile in
                    ChromeProfileButton(profile: profile) { state.onOpenProfile(profile) }
                        .frame(width: 64)
                }
            }
        }
        .padding(8)
        .frame(width: m.profilesCardWidth(group.chromeProfiles.count), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.top, m.cardPadding)
    }

    private func card(_ window: WindowInfo, icon: NSImage, appName: String) -> some View {
        let m = state.metrics
        let width = m.cardWidth(window)
        let target = SwitchTarget(window: window, tab: nil)
        let highlighted = isHighlighted(target.id)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let image = window.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .opacity(0.6)
                }
            }
            .frame(width: width, height: m.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let key = state.shortcut(for: target.id) {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 22, minHeight: 22)
                        .glassEffect(.regular, in: .rect(cornerRadius: 6, style: .continuous))
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if state.hovered == target.id {
                    CloseButton(size: 20) { state.onClose(target) }
                        .padding(5)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

            Text(window.title.isEmpty ? appName : window.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, height: m.titleHeight)
        }
        .padding(m.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(highlighted ? 0.28 : 0))
        )
        .contentShape(Rectangle())
        .modifier(Selectable(state: state, target: target))
    }

    private func isHighlighted(_ id: String) -> Bool {
        state.hovered == id || (state.hovered == nil && state.selected == id)
    }

    /// iTerm2 window as a compact list of its tabs.
    private func tabsCard(_ window: WindowInfo) -> some View {
        let m = state.metrics
        return VStack(spacing: 0) {
            ForEach(window.tabs) { tab in
                let target = SwitchTarget(window: window, tab: tab)
                HStack(spacing: 6) {
                    Text(state.shortcut(for: target.id) ?? "")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Circle()
                        .fill(Color.accentColor.opacity(tab.isCurrent ? 1 : 0))
                        .frame(width: 5, height: 5)
                    TabTitle(tab: tab)
                    Spacer(minLength: 0)
                    if state.hovered == target.id {
                        CloseButton(size: 14) { state.onClose(target) }
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: m.tabRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isHighlighted(target.id) ? 0.28 : 0))
                )
                .modifier(Selectable(state: state, target: target))
            }
        }
        .frame(width: m.tabCardWidth)
        .padding(m.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var permissionPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Nav needs Screen Recording permission to show window previews.")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            Text("Allow Nav in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Nav.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Open System Settings") { state.onOpenSettings() }
                Button("Restart Nav") { relaunch() }
            }
        }
        .padding(24)
    }
}

/// The configurable line around the popup: solid, or a (rotating) palette gradient.
struct PopupBorder: View {
    let config: Config.BorderConfig

    var body: some View {
        let colors = config.colors.map { Color(nsColor: $0) }
        let shape = RoundedRectangle(cornerRadius: CGFloat(config.cornerRadius + config.outset), style: .continuous)
            .inset(by: -CGFloat(config.outset) - CGFloat(config.width) / 2)
        TimelineView(.animation(paused: !config.animate || colors.count < 2)) { context in
            let angle = Angle.degrees(config.animate ? context.date.timeIntervalSinceReferenceDate * 60 : 0)
            let style: AnyShapeStyle = colors.count > 1
                ? AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center, angle: angle))
                : AnyShapeStyle(colors.first ?? .accentColor)
            shape
                .strokeBorder(style, lineWidth: CGFloat(config.width))
                .shadow(color: (colors.first ?? .accentColor).opacity(config.glow > 0 ? 0.9 : 0),
                        radius: CGFloat(config.glow) / 2)
        }
    }
}

/// "Title · domain", one line.
struct TabTitle: View {
    let tab: TabInfo

    var body: some View {
        HStack(spacing: 4) {
            if tab.isAudible { AudioIcon(size: 10) }
            Text(tab.title.isEmpty ? (tab.url ?? "Untitled") : tab.title)
                .font(.system(size: 11, weight: tab.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            if let domain = tab.domain {
                Text("· \(domain)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }
}

/// Badge on an app icon driven by Playwright & co.
struct AutomationBadge: View {
    let kind: AutomationKind
    let size: CGFloat

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: kind.color)))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .help("Started by \(kind.name)")
    }
}

/// 🔊 shown on apps / tabs that are playing sound.
struct AudioIcon: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
            .layoutPriority(1)   // a long title must not squeeze it out
            .help("Playing audio")
    }
}

struct CloseButton: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .frame(width: size, height: size)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

/// Hover highlights, click switches, and the id lets keyboard selection scroll into view.
struct Selectable: ViewModifier {
    @ObservedObject var state: WindowsState
    let target: SwitchTarget

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { state.hovered = target.id; state.selected = nil }
                else if state.hovered == target.id { state.hovered = nil }
            }
            .onTapGesture { state.onFocus(target) }
            .id(target.id)
    }
}

/// macOS only applies a new Screen Recording grant after the app restarts.
func relaunch() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 0.5; open \"$0\"", Bundle.main.bundleURL.path]
    try? task.run()
    NSApp.terminate(nil)
}
