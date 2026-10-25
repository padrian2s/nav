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
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 841, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Nav Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        // Nav is a background app; plain activate() is refused when another app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var border: Config.BorderConfig { model.config.popupBorder }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: general options and the live preview.
            Form {
                Section("General") {
                    Toggle("Open Nav at login", isOn: $model.config.launchAtLogin)
                    Picker("Theme", selection: $model.config.theme) {
                        Text("Modern").tag("modern")
                        Text("Classic").tag("classic")
                    }
                    .pickerStyle(.segmented)
                    Picker("Chrome profiles", selection: $model.config.chromeProfiles) {
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Pass ⌘E / ⌘⇧E to remote desktops", isOn: $model.config.passShortcutsToRemoteApps)
                        Text("While Screen Sharing, Remote Desktop, VNC or a VM is in front, the shortcuts go to the remote Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Hide the macOS Dock", isOn: $model.config.hideDock)
                        Text("Hidden while Nav runs (use ⌘E instead); it comes back when you quit Nav.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Preview") {
                    preview
                }

                Section {
                    HStack {
                        Button("Reset Border") { model.config.popupBorder = .init() }
                        Button("Open config.json") { NSWorkspace.shared.open(Config.url) }
                        Spacer()
                        Button("Quit Nav") { NSApp.terminate(nil) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)

            Divider()

            // Right: everything about the ⌘⇧E border.
            Form {
                Section("Popup border (⌘⇧E)") {
                    Toggle("Show a border around the popup", isOn: $model.config.popupBorder.enabled)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Colors")
                        palettePicker
                    }
                    .disabled(!border.enabled)

                    if border.palette == "solid" {
                        Toggle("Use the system accent color", isOn: Binding(get: { model.useAccent }, set: { model.useAccent = $0 }))
                            .disabled(!border.enabled)
                        if !model.useAccent {
                            ColorPicker("Color", selection: Binding(get: { model.color }, set: { model.color = $0 }), supportsOpacity: true)
                                .disabled(!border.enabled)
                        }
                    } else {
                        Toggle("Rotate the colors", isOn: $model.config.popupBorder.animate)
                            .disabled(!border.enabled)
                    }

                    slider("Width", $model.config.popupBorder.width, 1...20, step: 1, unit: "pt")
                    slider("Corner radius", $model.config.popupBorder.cornerRadius, 0...40, step: 1, unit: "pt")
                    slider("Outset", $model.config.popupBorder.outset, -10...20, step: 1, unit: "pt")
                    slider("Glow", $model.config.popupBorder.glow, 0...40, step: 1, unit: "pt")
                    slider("Opacity", $model.config.popupBorder.opacity, 0.1...1, step: 0.05, unit: "")
                }

                Section("Timing") {
                    Toggle("Fade out", isOn: $model.config.popupBorder.fade)
                        .disabled(!border.enabled)
                    slider("Visible for", $model.config.popupBorder.duration, 0.5...10, step: 0.5, unit: "s")
                        .disabled(!border.fade)
                    slider("Fade in", $model.config.popupBorder.fadeIn, 0...1, step: 0.05, unit: "s")
                    slider("Fade out", $model.config.popupBorder.fadeOut, 0...3, step: 0.1, unit: "s")
                        .disabled(!border.fade)
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)
        }
        .frame(height: 680)
    }

    /// A mini popup wearing the border exactly as configured.
    private var preview: some View {
        let b = border
        let radius = CGFloat(b.cornerRadius)
        return VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(["GTM Console · gtm.nstarxinc.com", "Call Floor UX improvement · claude.ai",
                               "Navigator macOS cu cmd+e"].enumerated()), id: \.offset) { i, title in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        Text(title).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .frame(width: 260)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(dockFrost))
                    .glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
            }
            .overlay {
                if b.enabled {
                    PopupBorder(config: b)
                        .opacity(model.previewOpacity ?? b.opacity)
                        .allowsHitTesting(false)
                }
            }
            .padding(b.margin)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 140)

            Button("Play fade") { model.play() }
                .disabled(!b.enabled)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var palettePicker: some View {
        HStack(spacing: 8) {
            swatch(id: "solid", name: "Solid", style: AnyShapeStyle(Color(nsColor: border.nsColor)))
            ForEach(BorderPalette.all) { p in
                swatch(id: p.id, name: p.name,
                       style: AnyShapeStyle(LinearGradient(colors: p.colors.map { Color(nsColor: $0) },
                                                           startPoint: .leading, endPoint: .trailing)))
            }
        }
    }

    private func swatch(id: String, name: String, style: AnyShapeStyle) -> some View {
        let selected = border.palette.lowercased() == id
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(style)
                .frame(width: 40, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 2)
                        .padding(-3)
                )
            Text(name)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.config.popupBorder.palette = id }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double, unit: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(step < 1 ? String(format: "%.2g%@", value.wrappedValue, unit) : "\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .disabled(!border.enabled)
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
