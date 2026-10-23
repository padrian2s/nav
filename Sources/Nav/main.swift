import AppKit
import Carbon.HIToolbox

// Change the global shortcuts here.
let dockHotKey = (code: kVK_ANSI_E, modifiers: cmdKey)
let windowsHotKey = (code: kVK_ANSI_E, modifiers: cmdKey | shiftKey)

Config.writeDefaultsIfMissing()
LoginItem.sync(Config.current.launchAtLogin)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let dock = DockController()
let windows = WindowsController()

func toggleDock() { windows.hide(); dock.toggle() }
func toggleWindows() { dock.hide(); windows.toggle() }

let hotKeys = [
    HotKey(keyCode: dockHotKey.code, modifiers: dockHotKey.modifiers, action: toggleDock),
    HotKey(keyCode: windowsHotKey.code, modifiers: windowsHotKey.modifiers, action: toggleWindows),
]

// Remote desktop / VM in front: let the shortcuts through to the remote machine.
func updateHotKeysForFrontmostApp() {
    let config = Config.current
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let pass = config.passShortcutsToRemoteApps && config.isRemoteApp(front)
    if pass { dock.hide(); windows.hide() }
    hotKeys.forEach { $0.isEnabled = !pass }
}
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                  object: nil, queue: .main) { _ in updateHotKeysForFrontmostApp() }
updateHotKeysForFrontmostApp()

// `kill -USR1 <pid>` / `kill -USR2 <pid>` toggle the dock / windows view — handy for scripting/testing.
var signalSources: [DispatchSourceSignal] = []
for (sig, action) in [(SIGUSR1, toggleDock), (SIGUSR2, toggleWindows)] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: action)
    source.resume()
    signalSources.append(source)
}

app.run()
