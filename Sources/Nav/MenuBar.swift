import AppKit

/// Nav's icon in the menu bar: open the popups, pick the ⌘Tab switcher, settings, quit.
/// The menu is rebuilt on every open so it shows the current ⌘Tab choice.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let actions: (windows: () -> Void, dock: () -> Void, claude: () -> Void)

    init(windows: @escaping () -> Void, dock: @escaping () -> Void, claude: @escaping () -> Void) {
        actions = (windows, dock, claude)
        super.init()
        let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Nav")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Nav"
        item.menu = NSMenu()
        item.menu?.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let commandTab = Config.current.commandTab
        // Run after the menu closes, so the popup gets the keyboard.
        func later(_ action: @escaping () -> Void) -> () -> Void { { DispatchQueue.main.async(execute: action) } }

        menu.addItem(ActionItem("Windows", key: commandTab ? "\t" : "e", modifiers: commandTab ? .command : [.command, .shift],
                                later(actions.windows)))
        menu.addItem(ActionItem("Dock", key: "e", modifiers: .command, later(actions.dock)))
        menu.addItem(ActionItem("Claude Sessions", key: "e", modifiers: [.command, .option], later(actions.claude)))
        let top = AppUsage.currentSlots()
        if let a = top[0], let b = top[1] {
            menu.addItem(ActionItem("Switch \(AppUsage.name(of: a)) ⇄ \(AppUsage.name(of: b))", key: "\t", modifiers: .option,
                                    AppUsage.switchTopTwo))
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: "⌘Tab switcher", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (title, on) in [("Nav", true), ("macOS", false)] {
            let choice = ActionItem(title) { SettingsWindowController.shared.setCommandTab(on) }
            choice.state = commandTab == on ? .on : .off
            choice.indentationLevel = 1
            menu.addItem(choice)
        }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Settings…", key: ",", modifiers: .command) { SettingsWindowController.shared.show() })
        menu.addItem(ActionItem("Quit Nav", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }
}
