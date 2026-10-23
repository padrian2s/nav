import AppKit
import CoreAudio

/// Which apps are playing sound right now, from CoreAudio's per-process list (macOS 14.4+).
enum AudioActivity {
    /// PIDs of apps with audio output running. Helper processes (e.g. Chrome's audio
    /// service) are mapped to the app responsible for them.
    static func playingApps() -> Set<pid_t> {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }

        var pids = Set<pid_t>()
        for object in objects where property(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0 {
            let pid = property(object, kAudioProcessPropertyPID, pid_t(0))
            guard pid > 0 else { continue }
            pids.insert(pid)
            pids.insert(responsibility_get_pid_responsible_for_pid(pid))
        }
        return pids
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : fallback
    }
}

/// Private but long-stable libsystem call: the app a helper/XPC process belongs to.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t
