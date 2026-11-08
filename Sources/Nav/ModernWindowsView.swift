import SwiftUI

/// Picks the ⌘⇧E look. Permission and "no windows" screens are shared (Classic).
struct SwitcherView: View {
    @ObservedObject var state: WindowsState

    var body: some View {
        if state.modern && !state.needsPermission && !state.groups.isEmpty {
            ModernWindowsView(state: state)
        } else {
            WindowsView(state: state)
        }
    }
}

/// Modern theme sizes. One-window apps are cards in a wrapping top row; apps with
/// several windows or tabs get a row each: app column + one list per window.
struct ModernMetrics {
    let hPadding: CGFloat = 24
    let topPadding: CGFloat = 20
    let footerHeight: CGFloat = 34
    let rowGap: CGFloat = 16
    // Cards
    let thumbHeight: CGFloat = 120
    var thumbWidth: CGFloat { thumbHeight * 16 / 10 }
    let cardPadding: CGFloat = 6
    let cardSpacing: CGFloat = 18
    var cardSize: CGSize { CGSize(width: thumbWidth + cardPadding * 2, height: thumbHeight + cardPadding * 2 + 20 + 18 + 10) }
    // Lists
    let headerWidth: CGFloat = 120
    let headerGap: CGFloat = 16
    let headerHeight: CGFloat = 92
    let listRowHeight: CGFloat = 28
    let listPadding: CGFloat = 4
    let listIdealWidth: CGFloat = 400
    let listMaxWidth: CGFloat = 460
    let listGap: CGFloat = 10
    let profilesWidth: CGFloat = 72
    let collapsedHeight: CGFloat = 92
    // Hover preview
    let peekWidth: CGFloat = 280

    /// Lists shown for an app: tabbed windows one each; plain windows share one list.
    func lists(_ g: AppWindows) -> [[SwitchTarget]] {
        let tabbed = g.windows.filter { !$0.tabs.isEmpty }.map { w in w.tabs.map { SwitchTarget(window: w, tab: $0) } }
        let plain = g.windows.filter { $0.tabs.isEmpty }.map { SwitchTarget(window: $0, tab: nil) }
        return tabbed + (plain.isEmpty ? [] : [plain])
    }

    func groupHeight(_ g: AppWindows, collapsed: Bool) -> CGFloat {
        if collapsed { return collapsedHeight }
        let rows = lists(g).map(\.count).max() ?? 1
        return max(CGFloat(rows) * listRowHeight + listPadding * 2, headerHeight)
    }

    func groupWidth(_ g: AppWindows) -> CGFloat {
        let n = CGFloat(lists(g).count)
        return headerWidth + headerGap + n * listIdealWidth + (n - 1) * listGap
            + (g.chromeProfiles.isEmpty ? 0 : listGap + profilesWidth)
    }

    /// Cards per line when the content is `width` wide.
    func cardsPerLine(_ width: CGFloat) -> Int {
        max(Int((width + cardSpacing) / (cardSize.width + cardSpacing)), 1)
    }

    func contentSize(_ state: WindowsState, maxWidth: CGFloat) -> CGSize {
        let singles = state.singles.count
        let multi = state.multiGroups
        let cardsWidth = CGFloat(singles) * (cardSize.width + cardSpacing) - cardSpacing
        let inner = min(max(cardsWidth, multi.map(groupWidth).max() ?? 0, 520), maxWidth - hPadding * 2)
        let cardLines = singles == 0 ? 0 : (singles + cardsPerLine(inner) - 1) / cardsPerLine(inner)
        let heights = (cardLines > 0 ? [CGFloat(cardLines) * cardSize.height + CGFloat(cardLines - 1) * 10] : [])
            + multi.map { groupHeight($0, collapsed: state.isCollapsed($0)) }
        let height = heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * rowGap
        return CGSize(width: inner + hPadding * 2, height: height + topPadding + 12 + footerHeight)
    }
}

/// Mouse position over a list row; observed only by the preview, so moving the
/// mouse doesn't redraw the whole popup.
final class PeekState: ObservableObject {
    @Published var id: String?
    @Published var point: CGPoint = .zero
}

/// Light palette from the "Window Switcher v2" design.
enum Palette {
    static let text = Color(rgb: 0x1E2227)
    static let secondary = Color(rgb: 0x6B7076)
    static let tertiary = Color(rgb: 0x7A7F85)
    static let backgroundTop = Color(rgb: 0xF6F8FA)
    static let backgroundBottom = Color(rgb: 0xEBEFF3)
    static let list = Color(rgb: 0xE6E9ED).opacity(0.85)
    static let selected = Color(rgb: 0xBDD5F7)
    static let activeDot = Color(rgb: 0x2F72E0)
    static let thumbBorder = Color(rgb: 0xD6D9DD)
    static let thumbFill = Color(rgb: 0xEFF1F4)
    static let chipBorder = Color(rgb: 0xCFD3D8)
    static let pill = Color(rgb: 0xE3E6EA)
    static let footer = Color(rgb: 0xEDF0F4)
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

struct ModernWindowsView: View {
    @ObservedObject var state: WindowsState
    private let m = ModernMetrics()
    private static let space = "modern"

    var body: some View {
        VStack(spacing: 0) {
            WithAppStrip(state.strip, modern: true) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: m.rowGap) {
                        ForEach(state.pinned) { row($0) }
                        if !state.singles.isEmpty {
                            FlowLayout(spacing: m.cardSpacing, lineSpacing: 10) {
                                ForEach(state.singles) { card($0) }
                            }
                        }
                        ForEach(state.unpinnedGroups) { row($0) }
                    }
                    .padding(.horizontal, m.hPadding)
                    .padding(.top, m.topPadding)
                    .padding(.bottom, 12)
                }
                .onChange(of: state.selected) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            }
            footer
        }
        .overlay { PeekView(state: state, peek: state.peek, metrics: m) }
        .coordinateSpace(name: Self.space)
        .foregroundStyle(Palette.text)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundBottom],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if state.border.enabled {
                PopupBorder(config: state.border)
                    .opacity(state.borderOpacity)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .light)
        .padding(state.border.margin)
    }

    private var radius: CGFloat { CGFloat(state.border.cornerRadius) }

    private func isHighlighted(_ id: String) -> Bool {
        state.hovered == id || (state.hovered == nil && state.selected == id)
    }

    // MARK: One-window apps

    private func card(_ g: AppWindows) -> some View {
        let window = g.windows[0]
        let target = SwitchTarget(window: window, tab: window.tabs.first)
        let on = isHighlighted(target.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                AppIcon(group: g, size: 20)
                Text(g.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let kind = g.automation { badge(kind) }
                if g.isAudible { AudioIcon(size: 10) }
            }
            .padding(.horizontal, 2)
            .frame(height: 20)
            thumbnail(window, icon: g.icon)
                .frame(width: m.thumbWidth, height: m.thumbHeight)
                .overlay(alignment: .topLeading) { hotkeyChip(target.id).padding(6) }
                .overlay(alignment: .topTrailing) {
                    if on { closeButton(target, size: 24).padding(6) }
                }
            Text(target.tab?.displayTitle ?? (window.title.isEmpty ? g.name : window.title))
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: m.thumbWidth, height: 18)
        }
        .padding(m.cardPadding)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Palette.selected : .clear))
        .modifier(Selectable(state: state, target: target))
    }

    private func thumbnail(_ window: WindowInfo, icon: NSImage) -> some View {
        ZStack {
            Palette.thumbFill
            if let image = window.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40).opacity(0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.thumbBorder))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private func hotkeyChip(_ id: String) -> some View {
        keyChip(state.shortcut(for: id))
    }

    private func keyChip(_ key: String?) -> some View {
        Group {
            if let key {
                Text(key)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(rgb: 0x2A2E33))
                    .frame(minWidth: 24, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.chipBorder))
            }
        }
    }

    private func badge(_ kind: AutomationKind) -> some View {
        Text(kind.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(nsColor: kind.color))
            .lineLimit(1)
    }

    private func closeButton(_ target: SwitchTarget, size: CGFloat) -> some View {
        Button { state.onClose(target) } label: {
            Text("×")
                .font(.system(size: size * 0.6))
                .foregroundStyle(Color(rgb: 0x3A3F45))
                .frame(width: size, height: size)
                .background(Circle().fill(.white))
                .overlay(Circle().strokeBorder(Palette.chipBorder))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Close (⌘W)")
    }

    // MARK: Apps with several windows / tabs

    private func row(_ g: AppWindows) -> some View {
        let collapsed = state.isCollapsed(g)
        return HStack(alignment: .center, spacing: m.headerGap) {
            Button { state.toggleCollapsed(g) } label: {
                VStack(spacing: 4) {
                    AppIcon(group: g, size: 44)
                        .overlay(alignment: .topLeading) { keyChip(state.appShortcut(g)).offset(x: -14, y: -6) }
                    HStack(spacing: 3) {
                        if g.isAudible { AudioIcon(size: 9) }
                        Text(g.name)
                            .font(.system(size: 13, weight: .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    if let kind = g.automation { badge(kind) }
                }
                .frame(width: m.headerWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(collapsed ? "Click to expand" : "Click to collapse")

            if collapsed {
                Button { state.toggleCollapsed(g) } label: {
                    Text("\(hiddenLabel(g)) · click to expand")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.pill))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: m.listGap) {
                    if !g.chromeProfiles.isEmpty && Config.current.profilesOnLeft { profiles(g) }
                    ForEach(Array(m.lists(g).enumerated()), id: \.offset) { _, items in
                        list(items, app: g)
                    }
                    if !g.chromeProfiles.isEmpty && !Config.current.profilesOnLeft { profiles(g) }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: m.groupHeight(g, collapsed: collapsed))
    }

    private func hiddenLabel(_ g: AppWindows) -> String {
        let tabs = g.windows.reduce(0) { $0 + $1.tabs.count }
        if tabs > 0 { return "\(tabs) \(tabs == 1 ? "tab" : "tabs") hidden" }
        return "\(g.windows.count) \(g.windows.count == 1 ? "window" : "windows") hidden"
    }

    private func list(_ items: [SwitchTarget], app g: AppWindows) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { target in listRow(target, app: g) }
        }
        .padding(m.listPadding)
        .frame(minWidth: 0, idealWidth: m.listIdealWidth, maxWidth: m.listMaxWidth)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.list))
    }

    private func listRow(_ target: SwitchTarget, app g: AppWindows) -> some View {
        let on = isHighlighted(target.id)
        let active = target.tab?.isCurrent ?? (g.windows.first?.id == target.window.id)
        let title = target.tab.map { $0.title.isEmpty ? ($0.url ?? "Untitled") : $0.displayTitle }
            ?? (target.window.title.isEmpty ? g.name : target.window.title)
        return HStack(spacing: 10) {
            Text(state.shortcut(for: target.id) ?? "")
                .font(.system(size: 13.5).monospacedDigit())
                .foregroundStyle(Palette.secondary)
                .frame(width: 16)
            Circle()
                .fill(active ? Palette.activeDot : .clear)
                .frame(width: 6, height: 6)
                .help(active ? "Active tab in this window" : "")
            HStack(spacing: 6) {
                if target.tab?.isAudible == true { AudioIcon(size: 10) }
                // "Title · domain" when both fit; otherwise the domain makes room.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        rowTitle(title, active: active)
                        if let domain = target.tab?.domain {
                            Text("· \(domain)")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }
                    rowTitle(title, active: active)
                }
            }
            Spacer(minLength: 0)
            if let claude = target.tab?.claude { ClaudeStatusPill(state: claude) }
            if on { closeButton(target, size: 22) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: m.listRowHeight)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.selected : .clear))
        .modifier(Selectable(state: state, target: target))
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            switch phase {
            case .active(let point):
                guard state.hoverPreview else { return }
                state.peek.id = target.id
                state.peek.point = point
            case .ended:
                if state.peek.id == target.id { state.peek.id = nil }
            }
        }
    }

    private func rowTitle(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 14, weight: active ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Closed Chrome profiles: click (or ⌥1…) opens a new window with that profile.
    private func profiles(_ g: AppWindows) -> some View {
        VStack(spacing: 6) {
            Text("+ window")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            ForEach(Array(g.chromeProfiles.prefix(9).enumerated()), id: \.element.id) { i, profile in
                Button { state.onOpenProfile(profile) } label: {
                    ProfileAvatar(profile: profile, size: 28)
                        .overlay(alignment: .bottomTrailing) {
                            Text("\(i + 1)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.white))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.chipBorder))
                                .offset(x: 6, y: 3)
                        }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("New Chrome window as \(profile.tooltip) (⌥\(i + 1))")
            }
        }
        .padding(6)
        .frame(width: m.profilesWidth)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.list))
    }

    // MARK: Footer

    private var footer: some View {
        let profiles = state.groups.first { !$0.chromeProfiles.isEmpty }?.chromeProfiles.count ?? 0
        let hints = (state.youTubeTarget == nil ? [] : ["Y YouTube"])
            + (state.fullScreenTarget == nil ? [] : ["F full screen"])
            + (state.editorTargets.isEmpty ? [] : [state.fullScreenTarget == nil ? "R F V editors" : "R V T editors"]) + ["1–0 A–Z switch", "↑↓ select", "↵ open", "⌘W close"]
            + (profiles > 0 ? ["⌥1–\(min(profiles, 9)) new window (profile)"] : [])
            + ["click app to collapse", "⌘Q quit"]
        return HStack(spacing: 4) {
            if state.hasClaudeTabs {
                ClaudeLegend()
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.trailing, 14)
            }
            Text(hints.joined(separator: "  ·  "))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: state.onToggleCommandTab) {
                Text(state.commandTab ? "⌘⇥ Nav" : "⌘⇥ macOS")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Palette.pill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(state.commandTab ? "⌘Tab opens Nav — click to use the macOS app switcher"
                                   : "⌘Tab is the macOS app switcher — click to use Nav")
            footerButton("power", help: "Quit Nav (brings the Dock back)") { NSApp.terminate(nil) }
            footerButton("gearshape", help: "Nav Settings (⌘,)") { state.onOpenPreferences() }
        }
        .padding(.horizontal, m.hPadding)
        .frame(height: m.footerHeight)
        .background(Palette.footer)
    }

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }
}

/// App icon with the automation badge (🎭 & co.) in the corner.
private struct AppIcon: View {
    let group: AppWindows
    let size: CGFloat

    var body: some View {
        Image(nsImage: group.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let kind = group.automation, size >= 32 {
                    AutomationBadge(kind: kind, size: size * 0.42).offset(x: 4, y: 4)
                }
            }
    }
}

/// Round profile picture, or its initial on the profile color.
struct ProfileAvatar: View {
    let profile: ChromeProfile
    let size: CGFloat

    var body: some View {
        Group {
            if let image = profile.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text(profile.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: profile.color))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Preview next to the mouse while it's over a list row: the window's picture when
/// it shows that row (plain window, or the window's current tab), else the app icon.
private struct PeekView: View {
    @ObservedObject var state: WindowsState
    @ObservedObject var peek: PeekState
    let metrics: ModernMetrics

    var body: some View {
        GeometryReader { geo in
            if let id = peek.id, let target = state.flat.first(where: { $0.id == id }) {
                let width = metrics.peekWidth
                let height = (width - 12) * 10 / 16 + 12 + 40
                let x = peek.point.x + 18 + width > geo.size.width - 8 ? peek.point.x - width - 18 : peek.point.x + 18
                let y = min(peek.point.y + 14, geo.size.height - height - 8)
                content(target)
                    .frame(width: width)
                    .offset(x: max(8, x), y: max(8, y))
                    .allowsHitTesting(false)
            }
        }
    }

    private func content(_ target: SwitchTarget) -> some View {
        let app = state.appFor(target.window)
        let showsWindow = target.tab == nil || target.tab?.isCurrent == true
        let title = target.tab?.displayTitle ?? target.window.title
        let sub = [app?.name, target.tab?.domain].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Palette.thumbFill
                if showsWindow, let image = target.window.image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else if let icon = app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48).opacity(0.6)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title.isEmpty ? (app?.name ?? "") : title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.top, 6)
            Text(sub)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.thumbBorder))
        .shadow(color: Color(rgb: 0x2A3A50).opacity(0.25), radius: 20, y: 18)
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
