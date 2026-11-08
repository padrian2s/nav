import AppKit
import Carbon.HIToolbox

/// A key with modifiers, written in config.json like "cmd+shift+e" ("" turns it off).
struct Shortcut: Equatable {
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags

    /// In the order macOS shows them: ⌃⌥⇧⌘.
    private static let modifierNames: [(name: String, flag: NSEvent.ModifierFlags, label: String, carbon: Int)] = [
        ("ctrl", .control, "⌃", controlKey), ("opt", .option, "⌥", optionKey),
        ("shift", .shift, "⇧", shiftKey), ("cmd", .command, "⌘", cmdKey),
    ]
    private static let allModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private static let functionKeys: [(code: Int, n: Int)] = [(122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6),
                                                              (98, 7), (100, 8), (101, 9), (109, 10), (103, 11), (111, 12)]

    /// Key code → config name, label, menu key equivalent ("" when a menu can't show it).
    private static let keys: [Int: (name: String, label: String, menu: String)] = {
        var keys: [Int: (name: String, label: String, menu: String)] = [:]
        let letters: [(Int, String)] = [(0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"),
                                        (8, "c"), (9, "v"), (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"),
                                        (16, "y"), (17, "t"), (31, "o"), (32, "u"), (34, "i"), (35, "p"), (37, "l"),
                                        (38, "j"), (40, "k"), (45, "n"), (46, "m")]
        let symbols: [(Int, String)] = [(18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"),
                                        (28, "8"), (25, "9"), (29, "0"), (24, "="), (27, "-"), (30, "]"), (33, "["),
                                        (39, "'"), (41, ";"), (42, "\\"), (43, ","), (44, "/"), (47, "."), (50, "`")]
        for (code, name) in letters { keys[code] = (name, name.uppercased(), name) }
        for (code, name) in symbols { keys[code] = (name, name, name) }
        for (code, name, label, menu) in [(48, "tab", "⇥", "\t"), (49, "space", "Space", " "), (36, "return", "↩", "\r"),
                                          (51, "delete", "⌫", "\u{8}"), (53, "esc", "⎋", "\u{1b}"),
                                          (123, "left", "←", ""), (124, "right", "→", ""), (125, "down", "↓", ""), (126, "up", "↑", "")] {
            keys[code] = (name, label, menu)
        }
        for (code, n) in functionKeys { keys[code] = ("f\(n)", "F\(n)", "") }
        return keys
    }()

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allModifiers)
    }

    init?(_ string: String) {
        var modifiers: NSEvent.ModifierFlags = []
        var code: Int?
        for part in string.lowercased().split(separator: "+").map(String.init) {
            if let m = Self.modifierNames.first(where: { $0.name == part }) {
                modifiers.insert(m.flag)
            } else if let k = Self.keys.first(where: { $0.value.name == part })?.key {
                code = k
            } else {
                return nil
            }
        }
        guard let code else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    /// A key press in the shortcut recorder: it needs a modifier, except for F1…F12.
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(Self.allModifiers)
        guard Self.keys[code] != nil, !modifiers.isEmpty || Self.functionKeys.contains(where: { $0.code == code })
        else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    private var names: [(name: String, flag: NSEvent.ModifierFlags, label: String, carbon: Int)] {
        Self.modifierNames.filter { modifiers.contains($0.flag) }
    }

    /// As written in config.json: "cmd+shift+e".
    var string: String { (names.map(\.name) + [Self.keys[keyCode]?.name ?? "?"]).joined(separator: "+") }
    /// As shown: "⇧⌘E".
    var label: String { names.map(\.label).joined() + (Self.keys[keyCode]?.label ?? "?") }
    /// One keycap per modifier, then the key: ["⇧", "⌘", "E"].
    var caps: [String] { names.map(\.label) + [Self.keys[keyCode]?.label ?? "?"] }
    var carbonModifiers: Int { names.reduce(0) { $0 | $1.carbon } }
    var menuKey: String { Self.keys[keyCode]?.menu ?? "" }
}

/// Everything with a global shortcut. Each can be remapped or turned off in Settings
/// (`shortcuts` in config.json, by `rawValue`).
enum NavAction: String, CaseIterable {
    case dock, windows, claude, switchTopTwo, key1, key2, key3, key4

    static let appKeys: [NavAction] = [.key1, .key2, .key3, .key4]

    var title: String {
        switch self {
        case .dock: "Dock"
        case .windows: "Windows view"
        case .claude: "Claude Sessions"
        case .switchTopTwo: "Switch between two apps"
        case .key1, .key2, .key3, .key4: "App key \(appIndex! + 1)"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .dock: "cmd+e"
        case .windows: "cmd+shift+e"
        case .claude: "cmd+opt+e"
        case .switchTopTwo: "opt+tab"
        case .key1, .key2, .key3, .key4: "opt+\(appIndex! + 1)"
        }
    }

    /// For the app keys: 0…3.
    var appIndex: Int? { Self.appKeys.firstIndex(of: self) }
}

extension Config {
    func shortcut(_ action: NavAction) -> Shortcut? {
        Shortcut(shortcuts[action.rawValue] ?? action.defaultShortcut)
    }
}

/// Nav's own features, which the app keys can open too ("nav:claude" in `appKeys`).
enum NavFeature: String, CaseIterable {
    case windows, dock, claude, settings

    private static let prefix = "nav:"
    var id: String { Self.prefix + rawValue }

    init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(id.dropFirst(Self.prefix.count)))
    }

    var title: String {
        switch self {
        case .windows: "Windows view"
        case .dock: "Dock"
        case .claude: "Claude Sessions"
        case .settings: "Nav Settings"
        }
    }

    var symbol: String {
        switch self {
        case .windows: "rectangle.3.group"
        case .dock: "dock.rectangle"
        case .claude: "sparkles"
        case .settings: "gearshape"
        }
    }

    /// Set by main.swift.
    static var run: (NavFeature) -> Void = { _ in }
}
