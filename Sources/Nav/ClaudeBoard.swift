import AppKit
import SwiftUI

/// A Claude Code session in an iTerm2 tab and what its screen shows.
struct ClaudeSession: Identifiable {
    let tab: TabInfo
    let screen: String
    var id: String { tab.id }
    var state: ClaudeState { tab.claude ?? .waiting }

    /// The conversation part of the screen: without Claude's input box and status
    /// lines at the bottom, and without blank lines.
    var preview: [String] {
        var lines = screen.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{0}", with: "") }
        let separators = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("──") }
        if separators.count >= 2 { lines = Array(lines[..<separators[separators.count - 2]]) }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Claude's status line: "Mulling… (1m 38s · ↓ 6.3k tokens)" while working,
    /// "Crunched for 1m 42s · done 6:56 PM" once done.
    var activity: String? {
        if state == .background { return ClaudeState.backgroundWork(in: screen) }
        return preview.last { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return "✳✶✻✽✢·*".contains(t.first ?? " ") && (t.contains("…") || t.contains(" for "))
        }.map { String($0.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces) }
    }
}

final class ClaudeBoardState: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var loaded = false
    @Published var selected: String?
    @Published var border = Config.BorderConfig()
    @Published var borderOpacity: Double = 0
    var onFocus: (ClaudeSession) -> Void = { _ in }

    /// Your turn first (they need you), then agents in the background, then working.
    func setSessions(_ new: [ClaudeSession]) {
        sessions = [ClaudeState.waiting, .background, .working].flatMap { s in new.filter { $0.state == s } }
        if !sessions.contains(where: { $0.id == selected }) { selected = sessions.first?.id }
    }

    var current: ClaudeSession? { sessions.first { $0.id == selected } ?? sessions.first }

    func shortcut(for id: String) -> String? {
        guard let i = sessions.firstIndex(where: { $0.id == id }), i < 10 else { return nil }
        return WindowsState.shortcutKeys[i]
    }

    func move(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        let i = sessions.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : sessions.count)
        selected = sessions[(i + delta + sessions.count) % sessions.count].id
    }
}

struct ClaudeMetrics {
    let listWidth: CGFloat = 330
    let rowHeight: CGFloat = 58
    let rowSpacing: CGFloat = 6
    let previewWidth: CGFloat = 820
    let previewHeight: CGFloat = 560
    let spacing: CGFloat = 16
    let padding: CGFloat = 22
    let headerHeight: CGFloat = 34
    let footerHeight: CGFloat = 34

    func contentSize(_ count: Int) -> CGSize {
        let n = CGFloat(max(count, 1))
        let list = n * rowHeight + (n - 1) * rowSpacing
        return CGSize(width: padding * 2 + listWidth + spacing + previewWidth,
                      height: headerHeight + max(list, previewHeight) + padding * 2 + footerHeight)
    }
}

/// ⌥⌘E: every Claude Code session in iTerm2 in a list, and the hovered / selected one's
/// screen in a big terminal next to it.
struct ClaudeBoardView: View {
    @ObservedObject var state: ClaudeBoardState
    private let m = ClaudeMetrics()

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.sessions.isEmpty {
                Text(state.loaded ? "No Claude Code sessions in iTerm2" : "Looking for Claude sessions…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: m.spacing) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: m.rowSpacing) {
                            ForEach(state.sessions) { row($0) }
                        }
                    }
                    .frame(width: m.listWidth)
                    if let session = state.current { preview(session) }
                }
                .padding(.horizontal, m.padding)
                .padding(.bottom, m.padding)
            }
            footer
        }
        .foregroundStyle(Palette.text)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundBottom],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if state.border.enabled {
                PopupBorder(config: state.border).opacity(state.borderOpacity).allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .light)
        .padding(state.border.margin)
    }

    private var radius: CGFloat { CGFloat(state.border.cornerRadius) }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Claude sessions")
                .font(.system(size: 15, weight: .semibold))
            ForEach([ClaudeState.waiting, .background, .working], id: \.self) { s in
                let n = state.sessions.filter { $0.state == s }.count
                if n > 0 { count(n, s) }
            }
            Spacer()
        }
        .padding(.horizontal, m.padding)
        .frame(height: m.headerHeight + 10, alignment: .bottom)
        .padding(.bottom, 10)
    }

    private func count(_ n: Int, _ s: ClaudeState) -> some View {
        HStack(spacing: 5) {
            ClaudeStatusIcon(state: s, size: 11)
            Text("\(n) \(s.label)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(s.color)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(s.color.opacity(0.14)))
    }

    /// Hovering a row shows its screen in the big preview; it stays there when the mouse leaves.
    private func row(_ session: ClaudeSession) -> some View {
        let on = state.selected == session.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let key = state.shortcut(for: session.id) {
                    Text(key)
                        .font(.system(size: 12, weight: .bold))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.chipBorder))
                }
                Text(title(session))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                ClaudeStatusPill(state: session.state)
            }
            Text(statusLine(session))
                .font(.system(size: 11.5))
                .foregroundStyle(session.state.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, state.shortcut(for: session.id) == nil ? 0 : 30)
        }
        .padding(.horizontal, 10)
        .frame(width: m.listWidth, height: m.rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Palette.selected : Palette.list))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(session.state.color.opacity(session.state == .waiting ? 0.7 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { inside in if inside { state.selected = session.id } }
        .onTapGesture { state.onFocus(session) }
        .help(session.tab.displayTitle)
    }

    private func statusLine(_ session: ClaudeSession) -> String {
        switch session.state {
        case .working: session.activity ?? "Working…"
        case .background: session.activity ?? "Agents running"
        case .waiting: ["Waiting for you", session.activity].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func title(_ session: ClaudeSession) -> String {
        let t = session.tab.displayTitle
        return t.hasSuffix(" (claude)") ? String(t.dropLast(9)) : t
    }

    /// The session's screen as a big terminal, newest lines at the bottom. Click opens the tab.
    private func preview(_ session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title(session))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ClaudeStatusPill(state: session.state)
                Spacer(minLength: 8)
                Text(statusLine(session))
                    .font(.system(size: 12))
                    .foregroundStyle(session.state.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: 22)
            // An overlay doesn't size its parent: lines that don't fit are cut off at the top.
            Color(rgb: 0x1C1F24)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(session.preview.suffix(80).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(rgb: 0xD8DEE6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, minHeight: m.previewHeight, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { state.onFocus(session) }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            ClaudeLegend()
                .padding(.trailing, 14)
            Text(["hover to preview", "1–0 switch", "↑↓ select", "↵ open", "esc close"].joined(separator: "  ·  "))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.tertiary)
        .padding(.horizontal, m.padding)
        .frame(height: m.footerHeight)
        .background(Palette.footer)
    }
}

/// ⌥⌘E: the Claude sessions board. Refreshes while open so the status stays live.
final class ClaudeBoardController {
    private let panel = DockPanel()
    private let state = ClaudeBoardState()
    private var refresh: Timer?
    private var borderGeneration = 0

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.contentView = NSHostingView(rootView: ClaudeBoardView(state: state))
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        state.onFocus = { [weak self] session in self?.focus(session) }
    }

    func toggle() { isVisible ? hide() : show() }

    func hide() {
        refresh?.invalidate()
        refresh = nil
        panel.dismiss()
    }

    func show() {
        state.border = Config.current.popupBorder
        state.selected = nil
        state.loaded = false
        Task { @MainActor in
            state.setSessions(await Tabs.fetchClaudeSessions())
            state.loaded = true
            let size = panelSize()
            panel.present(size: size, anchorY: size.height / 2)
            startBorder()
            refresh?.invalidate()
            refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.reload() }
            }
        }
    }

    @MainActor private func reload() async {
        guard panel.isVisible else { return }
        let sessions = await Tabs.fetchClaudeSessions()
        guard panel.isVisible else { return }
        let resize = sessions.count != state.sessions.count
        state.setSessions(sessions)
        if resize { panel.resize(to: panelSize()) }
    }

    private func panelSize() -> NSSize {
        let screen = panel.isVisible ? panel.screen
            : NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let vf = (screen ?? NSScreen.main!).visibleFrame
        let content = ClaudeMetrics().contentSize(state.sessions.count)
        let margin = state.border.margin * 2
        return NSSize(width: min(content.width, vf.width * 0.92) + margin,
                      height: min(content.height, vf.height * 0.85) + margin)
    }

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

    private func focus(_ session: ClaudeSession) {
        hide()
        Tabs.select(session.tab)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case 53: hide()                                        // Esc
        case 123, 126, 33: state.move(-1)                      // ←, ↑, [
        case 124, 125, 48, 30: state.move(1)                   // →, ↓, Tab, ]
        case 36, 76:                                           // Return, Enter
            if let s = state.current { focus(s) }
        case let code where numberRowKeys[code] != nil:        // 1…9, 0
            let i = numberRowKeys[code]!
            if state.sessions.indices.contains(i) { focus(state.sessions[i]) }
        default: return false
        }
        return true
    }
}
