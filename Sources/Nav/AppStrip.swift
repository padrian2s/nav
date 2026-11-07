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

final class AppStripHover: ObservableObject {
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
            case .top: VStack(spacing: 0) { bar; line(vertical: false); content }
            case .bottom: VStack(spacing: 0) { content; line(vertical: false); bar }
            case .left: HStack(spacing: 0) { bar; line(vertical: true); content }
            case .right: HStack(spacing: 0) { content; line(vertical: true); bar }
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

    var body: some View {
        let vertical = strip.config.placement.isVertical
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            if vertical {
                VStack(spacing: strip.spacing) { tiles }.padding(strip.padding)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: strip.spacing) { tiles }.padding(strip.padding)
                    .frame(maxHeight: .infinity)
            }
        }
        // Centered when everything fits.
        .defaultScrollAnchor(.center)
        .frame(width: vertical ? strip.thickness : nil, height: vertical ? nil : strip.thickness)
    }

    private var tiles: some View {
        ForEach(strip.items) { item in tile(item) }
    }

    private var ink: Color { modern ? Palette.text : .primary }

    private func tile(_ item: DockItem) -> some View {
        let on = hover.id == item.id
        let size = strip.iconSize
        return VStack(spacing: 2) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .scaleEffect(on ? 1.1 : 1)
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(ink.opacity(on ? 0.08 : 0))
            .padding(-4))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: on)
        .onHover { inside in
            if inside { hover.id = item.id } else if hover.id == item.id { hover.id = nil }
        }
        .onTapGesture { strip.onOpen(item) }
        .help(item.name)
    }
}
