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

        let config = Config.current
        func item(_ title: String, _ shortcut: Shortcut?, _ action: @escaping () -> Void) -> NSMenuItem {
            ActionItem(title, key: shortcut?.menuKey ?? "", modifiers: shortcut?.modifiers ?? [], action)
        }

        let windowsKey = commandTab ? Shortcut(keyCode: 48, modifiers: .command) : config.shortcut(.windows)
        menu.addItem(item("Windows", windowsKey, later(actions.windows)))
        menu.addItem(item("Dock", config.shortcut(.dock), later(actions.dock)))
        menu.addItem(item("Claude Sessions", config.shortcut(.claude), later(actions.claude)))
        if case let (a?, b?) = AppUsage.optionTabPair() {
            menu.addItem(item("Switch \(AppUsage.name(of: a)) ⇄ \(AppUsage.name(of: b))", config.shortcut(.switchTopTwo),
                              later(AppUsage.switchTopTwo)))
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

        if let version = Updater.shared.latestVersion {
            menu.addItem(ActionItem("Update to Nav \(version)") { Updater.shared.install() })
        } else {
            menu.addItem(ActionItem("Check for Updates") {
                Updater.shared.check()
                SettingsWindowController.shared.show(pane: .general)
            })
        }
        menu.addItem(ActionItem("Settings…", key: ",", modifiers: .command) { SettingsWindowController.shared.show() })
        menu.addItem(ActionItem("Quit Nav", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }
}
