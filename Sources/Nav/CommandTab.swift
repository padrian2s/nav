import AppKit

/// ⌘Tab / ⌘⇧Tab open Nav's windows view instead of the macOS app switcher; ⌘⇧E shows the
/// macOS one instead. The system shortcuts are switched off through SkyLight's private
/// symbolic-hotkey API (what AltTab does) and switched back on when Nav quits.
enum CommandTab {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private static let setEnabled: SetEnabled? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled")
        .map { unsafeBitCast($0, to: SetEnabled.self) }

    /// Symbolic hotkey ids: 1 = ⌘Tab, 2 = ⌘⇧Tab.
    private static let ids: [Int32] = [1, 2]

    /// The system state is per login session and outlives Nav, so every launch and quit sets it.
    static func setNative(_ enabled: Bool) {
        ids.forEach { _ = setEnabled?($0, enabled) }
    }

    private static var releaseTimer: Timer?

    /// Shows the macOS app switcher: hands ⌘Tab back to the system, posts one ⌘Tab while the
    /// user still holds ⌘ (from ⌘⇧E), and takes it again once ⌘ is released.
    static func showNativeSwitcher(handBack: @escaping () -> Void, takeBack: @escaping () -> Void) {
        releaseTimer?.invalidate()
        handBack()
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 48, keyDown: down)   // Tab
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) else { return }
            timer.invalidate()
            releaseTimer = nil
            takeBack()
        }
    }

    static var isShowingNative: Bool { releaseTimer != nil }
}
