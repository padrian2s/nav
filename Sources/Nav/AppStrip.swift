import SwiftUI

/// Where the ⌘E apps strip sits in the windows view (`appStrip.position` in config.json).
enum AppStripPosition: String, CaseIterable {
    case top, bottom, left, right

    var title: String { rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

/// The ⌘E dock's tiles (minus the ones turned off in Settings), then the added apps.
enum AppStrip {
    /// Everything that can be in the strip, in order; Settings lists these with a switch each.
    static func candidates(_ config: Config.AppStripConfig) -> [DockItem] {
        var items = DockModel.load().flatMap { $0 }
        let ids = Set(items.map(\.id))
        for path in config.extra where !ids.contains(path) && FileManager.default.fileExists(atPath: path) {
            items.append(DockModel.appItem(URL(fileURLWithPath: path)))
        }
        return items
    }

    static func items(_ config: Config.AppStripConfig) -> [DockItem] {
        let hidden = Set(config.hidden)
        return candidates(config).filter { !hidden.contains($0.id) }
    }
}

final class AppStripState: ObservableObject {
    @Published var items: [DockItem] = []
    @Published var config = Config.AppStripConfig()
    /// Hover lives apart, so moving the mouse over the strip only redraws the strip.
    let hover = AppStripHover()
    var onOpen: (DockItem) -> Void = { _ in }

    var isShown: Bool { config.enabled && !items.isEmpty }

    let padding: CGFloat = 10
    let spacing: CGFloat = 8
    var iconSize: CGFloat { CGFloat(config.iconSize) }
    private var nameHeight: CGFloat { config.names ? 15 : 0 }
    /// Width of one tile across the row (names need room).
    var tileWidth: CGFloat { config.names ? max(iconSize, 64) : iconSize }
    var tileHeight: CGFloat { iconSize + 6 + nameHeight }

    /// Across the strip: its height at the top / bottom, its width at the left / right.
    var thickness: CGFloat {
        padding * 2 + (config.placement.isVertical ? tileWidth : tileHeight)
    }

    /// Along the strip, for every tile without scrolling.
    var length: CGFloat {
        let tile = config.placement.isVertical ? tileHeight : tileWidth
        let n = CGFloat(items.count)
        return padding * 2 + n * tile + max(n - 1, 0) * spacing
    }

    /// The windows view's content size with the strip added (+1 for the line between them).
    func wrap(_ content: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard isShown else { return content }
        if config.placement.isVertical {
            return CGSize(width: content.width + thickness + 1, height: max(content.height, min(length, maxHeight)))
        }
        return CGSize(width: max(content.width, min(length, maxWidth)), height: content.height + thickness + 1)
    }
}

/// The mouse over the strip, in unmagnified coordinates along it.
final class AppStripHover: ObservableObject {
    @Published var along: CGFloat?
    @Published var id: String?
}

/// Puts the strip on its side of `content`.
struct WithAppStrip<Content: View>: View {
    @ObservedObject var strip: AppStripState
    let modern: Bool
    let content: Content

    init(_ strip: AppStripState, modern: Bool, @ViewBuilder content: () -> Content) {
        self.strip = strip
        self.modern = modern
        self.content = content()
    }

    var body: some View {
        if strip.isShown {
            let bar = AppStripView(strip: strip, hover: strip.hover, modern: modern)
            switch strip.config.placement {
            // The bar draws last-on-top, so magnified icons grow over the content.
            case .top: VStack(spacing: 0) { bar.zIndex(1); line(vertical: false); content }
            case .bottom: VStack(spacing: 0) { content; line(vertical: false); bar.zIndex(1) }
            case .left: HStack(spacing: 0) { bar.zIndex(1); line(vertical: true); content }
            case .right: HStack(spacing: 0) { content; line(vertical: true); bar.zIndex(1) }
            }
        } else {
            content
        }
    }

    private func line(vertical: Bool) -> some View {
        Rectangle()
            .fill(modern ? Color.black.opacity(0.08) : Color.primary.opacity(0.12))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct AppStripView: View {
    @ObservedObject var strip: AppStripState
    @ObservedObject var hover: AppStripHover
    let modern: Bool

    private var vertical: Bool { strip.config.placement.isVertical }
    /// One tile along the strip, unmagnified.
    private var step: CGFloat { vertical ? strip.tileHeight : strip.tileWidth }

    var body: some View {
        GeometryReader { geo in
            let room = vertical ? geo.size.height : geo.size.width
            // Everything fits: Dock-style magnification. Too many: a plain scrolling row.
            if strip.length <= room + 0.5 {
                magnified(room)
            } else {
                scrolling
            }
        }
        .frame(width: vertical ? strip.thickness : nil, height: vertical ? nil : strip.thickness)
    }

    // MARK: Magnification (the math of `DockState.scale`)

    private var maxScale: CGFloat {
        strip.config.magnify ? max(CGFloat(strip.config.hoverSize) / strip.iconSize, 1) : 1
    }

    private func baseCenter(_ i: Int) -> CGFloat {
        strip.padding + CGFloat(i) * (step + strip.spacing) + step / 2
    }

    private func scale(_ i: Int) -> CGFloat {
        guard maxScale > 1, let along = hover.along else { return 1 }
        let reach = strip.iconSize * 3
        let d = abs(along - baseCenter(i))
        guard d < reach else { return 1 }
        return 1 + (maxScale - 1) * cos(.pi * d / reach / 2)   // full size at the mouse, none at reach
    }

    /// How much the grown icons before `x` push it along (each icon grows around its center).
    private func pushed(before x: CGFloat) -> CGFloat {
        (0..<strip.items.count).reduce(0) { sum, i in
            let extra = strip.iconSize * (scale(i) - 1)
            let start = baseCenter(i) - step / 2
            return sum + extra * min(max((x - start) / step, 0), 1)
        }
    }

    /// Where tile `i`'s center goes: the icon under the mouse stays put, the others make room.
    private func center(_ i: Int, offset: CGFloat) -> CGFloat {
        guard let along = hover.along else { return baseCenter(i) + offset }
        return baseCenter(i) + pushed(before: baseCenter(i)) - pushed(before: along) + offset
    }

    /// Icons grow toward the windows (up from a bottom strip, right from a left one, …).
    private var anchor: UnitPoint {
        switch strip.config.placement {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private func magnified(_ room: CGFloat) -> some View {
        let offset = (room - strip.length) / 2   // centered
        return ZStack(alignment: .topLeading) {
            ForEach(Array(strip.items.enumerated()), id: \.element.id) { i, item in
                let c = center(i, offset: offset)
                tile(item, scale: scale(i))
                    .zIndex(Double(scale(i)))
                    .position(x: vertical ? strip.thickness / 2 : c, y: vertical ? c : strip.thickness / 2)
            }
        }
        .frame(width: vertical ? strip.thickness : room, height: vertical ? room : strip.thickness)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let along = (vertical ? p.y : p.x) - offset
                let i = Int((along - strip.padding + strip.spacing / 2) / (step + strip.spacing))
                hover.id = strip.items.indices.contains(i) ? strip.items[i].id : nil
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) { hover.along = along }
            case .ended:
                hover.id = nil
                withAnimation(.spring(response: 0.3)) { hover.along = nil }
            }
        }
    }

    private var scrolling: some View {
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            if vertical {
                VStack(spacing: strip.spacing) { plainTiles }.padding(strip.padding).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: strip.spacing) { plainTiles }.padding(strip.padding).frame(maxHeight: .infinity)
            }
        }
    }

    private var plainTiles: some View {
        ForEach(strip.items) { item in
            tile(item, scale: hover.id == item.id ? 1.1 : 1)
                .onHover { inside in
                    if inside { hover.id = item.id } else if hover.id == item.id { hover.id = nil }
                }
        }
    }

    private var ink: Color { modern ? Palette.text : .primary }

    private func tile(_ item: DockItem, scale: CGFloat) -> some View {
        let size = strip.iconSize
        return VStack(spacing: 2) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .scaleEffect(scale, anchor: anchor)
            Circle()
                .fill(ink.opacity(item.isRunning ? 0.65 : 0))
                .frame(width: 4, height: 4)
            if strip.config.names {
                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: strip.tileWidth, height: 13)
            }
        }
        .frame(width: strip.tileWidth, height: strip.tileHeight)
        .contentShape(Rectangle())
        .onTapGesture { strip.onOpen(item) }
        .help(item.name)
    }
}
