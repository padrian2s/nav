import Carbon.HIToolbox

/// System-wide hotkey via Carbon. Needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let hotKeyID: EventHotKeyID

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.installHandler()
        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.handlers[id] = action
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        hotKeyID = EventHotKeyID(signature: OSType(0x4E415600), id: id) // "NAV\0"
        isEnabled = true
        register()
    }

    /// Unregistered, the key combo reaches the frontmost app again (e.g. Screen Sharing,
    /// which forwards it to the remote Mac).
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? register() : unregister()
        }
    }

    private func register() {
        guard ref == nil else { return }
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("Nav: failed to register hotkey (status \(status)) — another app may own it")
        }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    deinit {
        unregister()
        HotKey.handlers[hotKeyID.id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
