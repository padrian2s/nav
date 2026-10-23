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

final class DockState: ObservableObject {
    @Published var sections: [[DockItem]] = [] { didSet { rebuild() } }
    @Published var metrics = DockMetrics.current()
    @Published var hoverX: CGFloat?          // in "base" (unmagnified) row coordinates
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

    /// Width of the row without magnification.
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

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = selected ?? (delta > 0 ? -1 : items.count)
        selected = (current + delta + items.count) % items.count
    }
}

struct DockView: View {
    @ObservedObject var state: DockState

    var body: some View {
        let m = state.metrics
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                row
                    .padding(.horizontal, m.padding)
                    .background(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: m.tileSize * 0.4, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(dockFrost))
                            .glassEffect(dockGlass, in: .rect(cornerRadius: m.tileSize * 0.4, style: .continuous))
                            .frame(height: m.tileSize + m.padding * 2 + 6)
                    }
                    .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    // Map panel x to unmagnified row x (row is centered in the panel).
                    let x = p.x - (geo.size.width - state.baseRowWidth) / 2
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                        state.hoverX = x
                    }
                case .ended:
                    withAnimation(.spring(response: 0.3)) { state.hoverX = nil }
                    state.hoveredIndex = nil
                }
            }
        }
    }

    private var row: some View {
        let m = state.metrics
        return HStack(alignment: .bottom, spacing: m.spacing) {
            ForEach(Array(state.slots.enumerated()), id: \.element.id) { i, slot in
                switch slot {
                case .separator:
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: m.tileSize * 0.82)
                        .frame(width: m.separatorWidth)
                        .padding(.bottom, m.padding + 3 + m.tileSize * 0.09)
                case .item(let item, let index):
                    tile(item, index: index, scale: state.scale(forSlot: i))
                }
            }
        }
    }

    private func tile(_ item: DockItem, index: Int, scale: CGFloat) -> some View {
        let m = state.metrics
        let size = m.tileSize * scale
        let showLabel = state.hoveredIndex == index || (state.hoveredIndex == nil && state.selected == index)
        return VStack(spacing: 0) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .brightness(state.pressed == item.id ? -0.25 : 0)
                .overlay(alignment: .top) {
                    if showLabel {
                        Text(item.name)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                            .offset(y: -34)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            Circle()
                .fill(Color.primary.opacity(item.isRunning ? 0.6 : 0))
                .frame(width: 4, height: 4)
                .padding(.top, 2)
                .padding(.bottom, m.padding - 1)
        }
        .padding(.top, m.padding)
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
}
