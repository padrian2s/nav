import AppKit
import Carbon.HIToolbox

// Change the global shortcuts here.
let dockHotKey = (code: kVK_ANSI_E, modifiers: cmdKey)
let windowsHotKey = (code: kVK_ANSI_E, modifiers: cmdKey | shiftKey)
let claudeHotKey = (code: kVK_ANSI_E, modifiers: cmdKey | optionKey)
// With `commandTab` on, these open the windows view and ⌘⇧E shows the macOS app switcher.
let commandTabHotKey = (code: kVK_Tab, modifiers: cmdKey)
let commandShiftTabHotKey = (code: kVK_Tab, modifiers: cmdKey | shiftKey)

Config.writeDefaultsIfMissing()
Config.current.save()   // persist values migrated from older configs (e.g. hideDock) before anything changes them
LoginItem.sync(Config.current.launchAtLogin)

// The Dock is hidden only while Nav runs.
if Config.current.hideDock, !MacDock.isHidden { MacDock.setHidden(true) }
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
    if Config.current.hideDock, MacDock.isHidden { MacDock.setHidden(false) }
    CommandTab.setNative(true)
}
// Off before Nav registers ⌘Tab, or the system keeps it.
CommandTab.setNative(!Config.current.commandTab)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let dock = DockController()
let windows = WindowsController()
let claudeBoard = ClaudeBoardController()

func toggleDock() { windows.hide(); claudeBoard.hide(); dock.toggle() }
func toggleWindows() { dock.hide(); claudeBoard.hide(); windows.toggle() }
func toggleClaudeBoard() { dock.hide(); windows.hide(); claudeBoard.toggle() }

/// ⌘Tab: opens the windows view; pressed again while it's open, ⌘Tab / ⌘⇧Tab go to the next / previous app.
func commandTab(step: Int) {
    if windows.isVisible { windows.moveSelection(step) } else { toggleWindows() }
}

func windowsShortcut() {
    guard Config.current.commandTab else { return toggleWindows() }
    dock.hide(); windows.hide(); claudeBoard.hide()
    CommandTab.showNativeSwitcher(handBack: {
        tabHotKeys.forEach { $0.isEnabled = false }
        CommandTab.setNative(true)
    }, takeBack: updateHotKeysForFrontmostApp)
}

let hotKeys = [
    HotKey(keyCode: dockHotKey.code, modifiers: dockHotKey.modifiers, action: toggleDock),
    HotKey(keyCode: windowsHotKey.code, modifiers: windowsHotKey.modifiers, action: windowsShortcut),
    HotKey(keyCode: claudeHotKey.code, modifiers: claudeHotKey.modifiers, action: toggleClaudeBoard),
]
let tabHotKeys = [
    HotKey(keyCode: commandTabHotKey.code, modifiers: commandTabHotKey.modifiers) { commandTab(step: 1) },
    HotKey(keyCode: commandShiftTabHotKey.code, modifiers: commandShiftTabHotKey.modifiers) { commandTab(step: -1) },
]

// Remote desktop / VM in front: let the shortcuts through to the remote machine.
func updateHotKeysForFrontmostApp() {
    let config = Config.current
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let pass = config.passShortcutsToRemoteApps && config.isRemoteApp(front)
    if pass { dock.hide(); windows.hide(); claudeBoard.hide() }
    hotKeys.forEach { $0.isEnabled = !pass }
    // Remote app in front: the system ⌘Tab comes back, so you can still switch away from it.
    let takeTab = config.commandTab && !pass
    guard !CommandTab.isShowingNative else { return }
    CommandTab.setNative(!takeTab)
    tabHotKeys.forEach { $0.isEnabled = takeTab }
}
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                  object: nil, queue: .main) { _ in updateHotKeysForFrontmostApp() }
updateHotKeysForFrontmostApp()

// `kill -USR1 / -USR2 / -INFO <pid>` toggle the dock / windows view / Claude board — handy for scripting/testing.
var signalSources: [DispatchSourceSignal] = []
// SIGTERM (`pkill Nav`) quits normally, so the system ⌘Tab gets switched back on.
for (sig, action) in [(SIGUSR1, toggleDock), (SIGUSR2, toggleWindows), (SIGINFO, toggleClaudeBoard),
                      (SIGTERM, { NSApp.terminate(nil) })] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: action)
    source.resume()
    signalSources.append(source)
}

app.run()
