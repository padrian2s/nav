import SwiftUI

/// Visual settings, read from the real Dock prefs so it matches the user's setup.
struct DockMetrics {
    var tileSize: CGFloat
    var largeSize: CGFloat
    var magnify: Bool
    let spacing: CGFloat = 4
    let padding: CGFloat = 8
    let separatorWidth: CGFloat = 17
    let labelHeight: CGFloat = 44
    /// Room for the name next to the icons when the dock is on the left / right edge.
    let labelWidth: CGFloat = 220
    let stackWidth: CGFloat = 400
    let stackRowHeight: CGFloat = 24
    let stackHeaderHeight: CGFloat = 32
    let stackWindowHeaderHeight: CGFloat = 20
    let stackGap: CGFloat = 10
    let stackProfilesWidth: CGFloat = 84

    func stackWidth(_ stack: DockStack) -> CGFloat {
        stackWidth + (stack.profiles.isEmpty ? 0 : stackProfilesWidth)
    }

    /// The glass row itself (icons + running dots).
    var rowHeight: CGFloat { tileSize + padding * 2 + 6 }

    func stackHeight(_ stack: DockStack) -> CGFloat {
        let headers = stack.windows.count > 1 ? CGFloat(stack.windows.count) * stackWindowHeaderHeight : 0
        let rows = CGFloat(stack.windows.reduce(0) { $0 + $1.tabs.count }) * stackRowHeight
        let tabs = stackHeaderHeight + headers + rows + 14
        let profiles = stack.profiles.isEmpty ? 0 : CGFloat(stack.profiles.count) * 50 + 34
        return min(max(tabs, profiles), 520)
    }

    static func current() -> DockMetrics {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let tile = CGFloat(prefs?.double(forKey: "tilesize") ?? 0)
        let large = CGFloat(prefs?.double(forKey: "largesize") ?? 0)
        let tileSize = tile > 0 ? tile : 64
        return DockMetrics(tileSize: tileSize,
                           largeSize: max(large > 0 ? large : 128, tileSize),
                           magnify: prefs?.bool(forKey: "magnification") ?? false)
    }

    var maxScale: CGFloat { magnify ? largeSize / tileSize : 1 }
}

/// Where ⌘E opens the dock (`dockPosition` in config.json).
enum DockPlacement: String, CaseIterable {
    case free, left, bottom, right

    var title: String {
        switch self {
        case .free: "Free"
        case .left: "Left"
        case .bottom: "Bottom"
        case .right: "Right"
        }
    }

    /// Left / right: the icons go top to bottom.
    var isVertical: Bool { self == .left || self == .right }
}

/// The real Dock uses the see-through "clear" glass, not the frosted "regular" one.
let dockGlass: Glass = ProcessInfo.processInfo.environment["NAV_GLASS"] == "regular" ? .regular : .clear

/// Light frost over the clear glass so text behind is ghosted, like the real Dock.
let dockFrost = Double(ProcessInfo.processInfo.environment["NAV_FROST"] ?? "") ?? 0.35

enum DockSlot: Identifiable {
    case item(DockItem, index: Int)
    case separator(Int)

    var id: String {
        switch self {
        case .item(let item, _): return item.id
        case .separator(let n): return "sep-\(n)"
        }
    }
}

/// Tabs of a tab-capable app (Chrome, iTerm2), shown above its icon like a Dock stack.
struct DockStack {
    let item: DockItem
    var windows: [TabWindow]
    var profiles: [ChromeProfile] = []   // Chrome profiles with no window open
    var tabs: [TabInfo] { windows.flatMap(\.tabs) }
}

final class DockState: ObservableObject {
    @Published var stack: DockStack?
    @Published var stackHovered: String?
    @Published var stackSelected: String?
    var onSelectTab: (TabInfo) -> Void = { _ in }
    var onCloseTab: (TabInfo) -> Void = { _ in }
    var onOpenApp: (DockItem) -> Void = { _ in }
    var onOpenProfile: (ChromeProfile) -> Void = { _ in }

    @Published var sections: [[DockItem]] = [] { didSet { rebuild() } }
    @Published var metrics = DockMetrics.current()
    @Published var placement = DockPlacement.free
    @Published var hoverX: CGFloat?          // along the row (down it when vertical), in "base" (unmagnified) coordinates
    @Published var selected: Int?            // keyboard selection
    @Published var pressed: String?
    @Published var hoveredIndex: Int?

    private(set) var slots: [DockSlot] = []
    private(set) var items: [DockItem] = []
    var onOpen: (DockItem) -> Void = { _ in }

    private func rebuild() {
        slots = []
        items = []
        for (n, section) in sections.enumerated() {
            if n > 0 { slots.append(.separator(n)) }
            for item in section {
                slots.append(.item(item, index: items.count))
                items.append(item)
            }
        }
    }

    /// Length of the row without magnification (its height when vertical).
    var baseRowWidth: CGFloat {
        let m = metrics
        let widths = slots.map { slot -> CGFloat in
            if case .separator = slot { return m.separatorWidth }
            return m.tileSize
        }
        return widths.reduce(0, +) + m.spacing * CGFloat(max(widths.count - 1, 0)) + m.padding * 2
    }

    /// Centers of each slot in base coordinates.
    func baseCenters() -> [CGFloat] {
        let m = metrics
        var x = m.padding
        return slots.map { slot in
            let w: CGFloat = { if case .separator = slot { return m.separatorWidth }; return m.tileSize }()
            defer { x += w + m.spacing }
            return x + w / 2
        }
    }

    func scale(forSlot i: Int) -> CGFloat {
        guard metrics.magnify, let hx = hoverX else { return 1 }
        let center = baseCenters()[i]
        let reach = metrics.tileSize * 3
        let d = abs(hx - center)
        guard d < reach else { return 1 }
        let t = cos(.pi * d / reach / 2)   // 1 at the cursor, 0 at reach
        return 1 + (metrics.maxScale - 1) * t
    }

    func moveInStack(_ delta: Int) {
        guard let tabs = stack?.tabs, !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == (stackSelected ?? stackHovered) } ?? (delta > 0 ? -1 : tabs.count)
        stackSelected = tabs[(i + delta + tabs.count) % tabs.count].id
        stackHovered = nil
    }

    func centerOfItem(_ id: String) -> CGFloat? {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return nil }
        return baseCenters()[i]
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = selected ?? (delta > 0 ? -1 : items.count)
        selected = (current + delta + items.count) % items.count
    }
}

struct DockView: View {
    @ObservedObject var state: DockState

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Group {
                if state.placement.isVertical { vertical(size) } else { horizontal(size) }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard state.stack == nil else { state.hoverX = nil; return }
                    // Map the panel point to the unmagnified row (the row is centered in the panel).
                    let along = state.placement.isVertical
                        ? p.y - (size.height - state.baseRowWidth) / 2
                        : p.x - (size.width - state.baseRowWidth) / 2
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                        state.hoverX = along
                    }
                case .ended:
                    withAnimation(.spring(response: 0.3)) { state.hoverX = nil }
                    state.hoveredIndex = nil
                }
            }
        }
    }

    /// Row at the bottom, tab lists above it.
    private func horizontal(_ size: CGSize) -> some View {
        let m = state.metrics
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let stack = state.stack, let center = state.centerOfItem(stack.item.id) {
                let available = size.height - m.rowHeight - m.stackGap
                let width = m.stackWidth(stack)
                let x = center + (size.width - state.baseRowWidth) / 2 - width / 2
                DockStackView(state: state, stack: stack)
                    .frame(width: width, height: min(m.stackHeight(stack), available))
                    .padding(.leading, min(max(x, 8), size.width - width - 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, m.stackGap)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            HStack(alignment: .bottom, spacing: m.spacing) { slots }
                .padding(.horizontal, m.padding)
                .background(alignment: .bottom) { glass.frame(height: m.rowHeight) }
                .frame(maxWidth: .infinity)
        }
    }

    /// Column against the left / right edge, tab lists beside it.
    private func vertical(_ size: CGSize) -> some View {
        let m = state.metrics
        let left = state.placement == .left
        let column = VStack(alignment: left ? .leading : .trailing, spacing: m.spacing) { slots }
            .padding(.vertical, m.padding)
            .background(alignment: left ? .leading : .trailing) { glass.frame(width: m.rowHeight) }
            .frame(maxHeight: .infinity)
        return HStack(spacing: 0) {
            if left { column } else { Spacer(minLength: 0) }
            if let stack = state.stack, let center = state.centerOfItem(stack.item.id) {
                let height = min(m.stackHeight(stack), size.height - 16)
                let y = center + (size.height - state.baseRowWidth) / 2 - height / 2
                DockStackView(state: state, stack: stack)
                    .frame(width: m.stackWidth(stack), height: height)
                    .padding(.top, min(max(y, 8), size.height - height - 8))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(left ? .leading : .trailing, m.stackGap)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: left ? .leading : .trailing)))
            }
            if left { Spacer(minLength: 0) } else { column }
        }
    }

    private var glass: some View {
        let m = state.metrics
        return RoundedRectangle(cornerRadius: m.tileSize * 0.4, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(dockFrost))
            .glassEffect(dockGlass, in: .rect(cornerRadius: m.tileSize * 0.4, style: .continuous))
    }

    private var slots: some View {
        ForEach(Array(state.slots.enumerated()), id: \.element.id) { i, slot in
            switch slot {
            case .separator: separator
            case .item(let item, let index): tile(item, index: index, scale: state.scale(forSlot: i))
            }
        }
    }

    @ViewBuilder private var separator: some View {
        let m = state.metrics
        let line = Rectangle().fill(Color.primary.opacity(0.22))
        let inset = m.padding + 3 + m.tileSize * 0.09
        switch state.placement {
        case .left, .right:
            line.frame(width: m.tileSize * 0.82, height: 1)
                .frame(height: m.separatorWidth)
                .padding(state.placement == .left ? .leading : .trailing, inset)
        case .free, .bottom:
            line.frame(width: 1, height: m.tileSize * 0.82)
                .frame(width: m.separatorWidth)
                .padding(.bottom, inset)
        }
    }

    private func tile(_ item: DockItem, index: Int, scale: CGFloat) -> some View {
        let m = state.metrics
        let size = m.tileSize * scale
        let showLabel = state.stack == nil
            && (state.hoveredIndex == index || (state.hoveredIndex == nil && state.selected == index))
        let icon = Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .brightness(state.pressed == item.id ? -0.25 : 0)
            .overlay(alignment: .bottomTrailing) {
                if let kind = item.automation {
                    AutomationBadge(kind: kind, size: size * 0.34).offset(x: size * 0.04, y: size * 0.04)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.isAudible {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: size * 0.16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(size * 0.07)
                        .glassEffect(.regular, in: .circle)
                        .offset(x: size * 0.06, y: -size * 0.06)
                        .help("Playing audio")
                }
            }
            .overlay(alignment: labelAlignment) {
                if showLabel { label(item.name, iconSize: size) }
            }
        let dot = Circle()
            .fill(Color.primary.opacity(item.isRunning ? 0.6 : 0))
            .frame(width: 4, height: 4)
        // The running dot sits on the screen-edge side of the icon, like the real Dock.
        return Group {
            switch state.placement {
            case .left:
                HStack(spacing: 0) { dot.padding(.leading, m.padding - 1).padding(.trailing, 2); icon }
                    .padding(.trailing, m.padding)
            case .right:
                HStack(spacing: 0) { icon; dot.padding(.leading, 2).padding(.trailing, m.padding - 1) }
                    .padding(.leading, m.padding)
            case .free, .bottom:
                VStack(spacing: 0) { icon; dot.padding(.top, 2).padding(.bottom, m.padding - 1) }
                    .padding(.top, m.padding)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { state.hoveredIndex = index; state.selected = nil }
            else if state.hoveredIndex == index { state.hoveredIndex = nil }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in state.pressed = item.id }
                .onEnded { _ in
                    state.pressed = nil
                    state.onOpen(item)
                }
        )
    }

    private var labelAlignment: Alignment {
        switch state.placement {
        case .left: .leading
        case .right: .trailing
        case .free, .bottom: .top
        }
    }

    /// The app's name: above the icon, or beside it when the dock is on the left / right.
    private func label(_ name: String, iconSize: CGFloat) -> some View {
        let text = Text(name)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
        let gap: CGFloat = 14
        return Group {
            switch state.placement {
            case .left: text.alignmentGuide(.leading) { _ in -(iconSize + gap) }
            case .right: text.alignmentGuide(.trailing) { d in d.width + iconSize + gap }
            case .free, .bottom: text.offset(y: -34)
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

/// The tab list that pops up above Chrome / iTerm2.
struct DockStackView: View {
    @ObservedObject var state: DockState
    let stack: DockStack

    var body: some View {
        let all = stack.tabs
        let left = Config.current.profilesOnLeft
        HStack(spacing: 0) {
            if left && !stack.profiles.isEmpty { profilesColumn; Divider().padding(.vertical, 8) }
            tabsList(all)
            if !left && !stack.profiles.isEmpty { Divider().padding(.vertical, 8); profilesColumn }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.3))
                .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    /// Closed Chrome profiles, one under the other.
    private var profilesColumn: some View {
        VStack(spacing: 6) {
            Text("Profiles")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: state.metrics.stackHeaderHeight)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(stack.profiles) { profile in
                        ChromeProfileButton(profile: profile) { state.onOpenProfile(profile) }
                    }
                }
            }
        }
        .frame(width: state.metrics.stackProfilesWidth)
    }

    private func tabsList(_ all: [TabInfo]) -> some View {
        let m = state.metrics
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: stack.item.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(stack.item.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(all.count) tab\(all.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: m.stackHeaderHeight)
            .contentShape(Rectangle())
            .onTapGesture { state.onOpenApp(stack.item) }
            .help("Open \(stack.item.name)")

            Divider().padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stack.windows.enumerated()), id: \.offset) { n, window in
                            if stack.windows.count > 1 {
                                Text("Window \(n + 1)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                                    .frame(height: m.stackWindowHeaderHeight, alignment: .bottomLeading)
                            }
                            ForEach(window.tabs) { tab in
                                row(tab, number: all.firstIndex { $0.id == tab.id })
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.stackSelected) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }

        }
    }

    private func row(_ tab: TabInfo, number: Int?) -> some View {
        let highlighted = state.stackHovered == tab.id || (state.stackHovered == nil && state.stackSelected == tab.id)
        return HStack(spacing: 6) {
            Text(number.flatMap { $0 < 10 ? ($0 == 9 ? "0" : "\($0 + 1)") : nil } ?? "")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Circle()
                .fill(Color.accentColor.opacity(tab.isCurrent ? 1 : 0))
                .frame(width: 5, height: 5)
            TabTitle(tab: tab)
            Spacer(minLength: 0)
            if state.stackHovered == tab.id {
                CloseButton(size: 14) { state.onCloseTab(tab) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: state.metrics.stackRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(highlighted ? 0.28 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { state.stackHovered = tab.id; state.stackSelected = nil }
            else if state.stackHovered == tab.id { state.stackHovered = nil }
        }
        .onTapGesture { state.onSelectTab(tab) }
        .id(tab.id)
    }
}
