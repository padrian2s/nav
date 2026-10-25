import AppKit
import Carbon.HIToolbox

// Change the global shortcuts here.
let dockHotKey = (code: kVK_ANSI_E, modifiers: cmdKey)
let windowsHotKey = (code: kVK_ANSI_E, modifiers: cmdKey | shiftKey)
let claudeHotKey = (code: kVK_ANSI_E, modifiers: cmdKey | optionKey)

Config.writeDefaultsIfMissing()
Config.current.save()   // persist values migrated from older configs (e.g. hideDock) before anything changes them
LoginItem.sync(Config.current.launchAtLogin)

// The Dock is hidden only while Nav runs.
if Config.current.hideDock, !MacDock.isHidden { MacDock.setHidden(true) }
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
    if Config.current.hideDock, MacDock.isHidden { MacDock.setHidden(false) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let dock = DockController()
let windows = WindowsController()
let claudeBoard = ClaudeBoardController()

func toggleDock() { windows.hide(); claudeBoard.hide(); dock.toggle() }
func toggleWindows() { dock.hide(); claudeBoard.hide(); windows.toggle() }
func toggleClaudeBoard() { dock.hide(); windows.hide(); claudeBoard.toggle() }

let hotKeys = [
    HotKey(keyCode: dockHotKey.code, modifiers: dockHotKey.modifiers, action: toggleDock),
    HotKey(keyCode: windowsHotKey.code, modifiers: windowsHotKey.modifiers, action: toggleWindows),
    HotKey(keyCode: claudeHotKey.code, modifiers: claudeHotKey.modifiers, action: toggleClaudeBoard),
]

// Remote desktop / VM in front: let the shortcuts through to the remote machine.
func updateHotKeysForFrontmostApp() {
    let config = Config.current
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let pass = config.passShortcutsToRemoteApps && config.isRemoteApp(front)
    if pass { dock.hide(); windows.hide(); claudeBoard.hide() }
    hotKeys.forEach { $0.isEnabled = !pass }
}
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                  object: nil, queue: .main) { _ in updateHotKeysForFrontmostApp() }
updateHotKeysForFrontmostApp()

// `kill -USR1 / -USR2 / -INFO <pid>` toggle the dock / windows view / Claude board — handy for scripting/testing.
var signalSources: [DispatchSourceSignal] = []
for (sig, action) in [(SIGUSR1, toggleDock), (SIGUSR2, toggleWindows), (SIGINFO, toggleClaudeBoard)] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: action)
    source.resume()
    signalSources.append(source)
}

app.run()
