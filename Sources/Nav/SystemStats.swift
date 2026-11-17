import AppKit
import Darwin
import IOKit
import SwiftUI

/// How worrying a number is. The menu bar icon takes the worst level of the moment.
enum StatLevel: Int, Comparable {
    case ok, warn, bad
    static func < (a: StatLevel, b: StatLevel) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .ok: .primary
        case .warn: .orange
        case .bad: .red
        }
    }
}

/// One reading of the things that slow the Mac down.
struct SystemSample {
    var at: Date
    /// Percent of memory macOS considers free (what `memory_pressure` reports).
    var memoryFree: Int
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// 1-minute load average.
    var load: Double
    var cores: Int
    /// Bytes per second since the previous sample.
    var diskRead: Double
    var diskWrite: Double

    var memoryLevel: StatLevel { memoryFree < 15 ? .bad : memoryFree < 30 ? .warn : .ok }
    var swapLevel: StatLevel { Self.level(Double(swapUsed), warn: 10 * gb, bad: 20 * gb) }
    var loadLevel: StatLevel { Self.level(load / Double(max(cores, 1)), warn: 0.5, bad: 0.9) }
    var level: StatLevel { max(memoryLevel, swapLevel, loadLevel) }

    static func level(_ value: Double, warn: Double, bad: Double) -> StatLevel {
        value >= bad ? .bad : value >= warn ? .warn : .ok
    }
}

private let gb = 1_073_741_824.0

/// A process and the memory it holds (the "Memory" column in Activity Monitor).
struct ProcessUsage: Identifiable {
    let pid: pid_t
    let name: String
    /// Its arguments, paths shortened to file names, e.g. "serena start-mcp-server".
    let command: String
    let footprint: UInt64
    var id: pid_t { pid }
    var level: StatLevel { SystemSample.level(Double(footprint), warn: 4 * gb, bad: 12 * gb) }
}

/// Reads the numbers straight from the kernel: no shelling out.
enum SystemProbe {
    static func sample(previousDisk: (read: UInt64, written: UInt64, at: Date)?) -> (SystemSample, (UInt64, UInt64, Date)) {
        let now = Date()
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let memoryFree = sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : 100

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) != 0 { swap = xsw_usage() }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        let disk = diskBytes()
        var read = 0.0, write = 0.0
        if let previous = previousDisk {
            let seconds = max(now.timeIntervalSince(previous.at), 0.001)
            read = Double(disk.read &- previous.read) / seconds
            write = Double(disk.written &- previous.written) / seconds
            if disk.read < previous.read || disk.written < previous.written { read = 0; write = 0 }  // disk came or went
        }
        let sample = SystemSample(at: now, memoryFree: memoryFree, swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
                                  load: loads[0], cores: ProcessInfo.processInfo.activeProcessorCount,
                                  diskRead: read, diskWrite: write)
        return (sample, (disk.read, disk.written, now))
    }

    /// Total bytes read and written by every block storage device since boot.
    static func diskBytes() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }

    /// The `count` processes holding the most memory. Only the user's own processes can be read.
    static func topProcesses(_ count: Int) -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var usage: [(pid: pid_t, footprint: UInt64)] = []
        for pid in pids.prefix(max(found, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if result == 0 { usage.append((pid, info.ri_phys_footprint)) }
        }
        return usage.sorted { $0.footprint > $1.footprint }.prefix(count).map {
            ProcessUsage(pid: $0.pid, name: name(of: $0.pid), command: command(of: $0.pid), footprint: $0.footprint)
        }
    }

    static func name(of pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }

    /// The process arguments (KERN_PROCARGS2), without argv[0], paths cut to their last component.
    static func command(of pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return "" }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }  // executable path
        while i < size, buffer[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args.dropFirst()
            .map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
            .joined(separator: " ")
    }
}

/// Samples every 10 s in the background (cheap: a few sysctls) to keep an hour of history and the icon's color,
/// every 2 s with the process list while the popover is open.
final class SystemStats: ObservableObject {
    @Published private(set) var current: SystemSample?
    @Published private(set) var worst: SystemSample?
    @Published private(set) var processes: [ProcessUsage] = []

    /// Called on the main queue with the worst level of the moment.
    var onLevel: ((StatLevel) -> Void)?

    private var history: [SystemSample] = []
    private var lastDisk: (read: UInt64, written: UInt64, at: Date)?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "nav.system-stats", qos: .utility)

    var detailed = false {
        didSet { if detailed != oldValue { schedule() } }
    }

    func start() { schedule() }

    private func schedule() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: detailed ? 2 : 10, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = detailed ? 0.2 : 2
    }

    private func refresh() {
        let previous = lastDisk
        let withProcesses = detailed
        queue.async { [weak self] in
            let (sample, disk) = SystemProbe.sample(previousDisk: previous)
            let processes = withProcesses ? SystemProbe.topProcesses(6) : nil
            DispatchQueue.main.async { self?.apply(sample, disk: disk, processes: processes) }
        }
    }

    private func apply(_ sample: SystemSample, disk: (UInt64, UInt64, Date), processes: [ProcessUsage]?) {
        lastDisk = disk
        let hourAgo = sample.at.addingTimeInterval(-3600)
        history.removeAll { $0.at < hourAgo }
        history.append(sample)
        current = sample
        worst = SystemSample(at: sample.at,
                             memoryFree: history.map(\.memoryFree).min() ?? sample.memoryFree,
                             swapUsed: history.map(\.swapUsed).max() ?? sample.swapUsed,
                             swapTotal: history.map(\.swapTotal).max() ?? sample.swapTotal,
                             load: history.map(\.load).max() ?? sample.load,
                             cores: sample.cores,
                             diskRead: history.map(\.diskRead).max() ?? sample.diskRead,
                             diskWrite: history.map(\.diskWrite).max() ?? sample.diskWrite)
        if let processes { self.processes = processes }
        let topProcess = self.processes.map(\.level).max() ?? .ok
        onLevel?(max(sample.level, detailed ? topProcess : .ok))
    }
}

/// Nav's second menu bar icon: a gauge that turns orange or red when memory, swap or load get bad,
/// and opens a popover with the numbers.
final class SystemStatsItem: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let stats = SystemStats()
    private let popover = NSPopover()

    override init() {
        super.init()
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "System")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "System"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: SystemStatsView(stats: stats))
        stats.onLevel = { [weak self] level in self?.show(level) }
        stats.start()
    }

    private func show(_ level: StatLevel) {
        item.button?.contentTintColor = switch level {
        case .ok: nil
        case .warn: .systemOrange
        case .bad: .systemRed
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            stats.detailed = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) { stats.detailed = false }
}

struct SystemStatsView: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let now = stats.current, let worst = stats.worst {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Now").foregroundStyle(.secondary)
                        Text("Worst, last hour").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Free memory", "\(now.memoryFree)%", now.memoryLevel, "\(worst.memoryFree)%", worst.memoryLevel)
                    row("Swap", swap(now), now.swapLevel, swap(worst), worst.swapLevel)
                    row("Load", load(now), now.loadLevel, load(worst), worst.loadLevel)
                    row("Disk", disk(now), .ok, disk(worst), .ok)
                }
                .monospacedDigit()
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Using the most memory").font(.caption).foregroundStyle(.secondary)
                ForEach(stats.processes) { process in
                    ProcessRow(process: process)
                }
            }

            HStack {
                Spacer()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ title: String, _ now: String, _ nowLevel: StatLevel, _ worst: String, _ worstLevel: StatLevel)
        -> some View {
        GridRow {
            Text(title)
            Text(now).foregroundStyle(nowLevel.color).fontWeight(nowLevel == .ok ? .regular : .semibold)
            Text(worst).foregroundStyle(worstLevel == .ok ? Color.secondary : worstLevel.color)
        }
    }

    private func swap(_ sample: SystemSample) -> String {
        sample.swapUsed == 0 ? "none" : bytes(Double(sample.swapUsed))
    }

    private func load(_ sample: SystemSample) -> String {
        String(format: "%.1f of %d cores", sample.load, sample.cores)
    }

    private func disk(_ sample: SystemSample) -> String {
        let total = sample.diskRead + sample.diskWrite
        if total < 512 * 1024 { return "idle" }
        return "↓\(bytes(sample.diskRead))/s ↑\(bytes(sample.diskWrite))/s"
    }
}

private func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

private struct ProcessRow: View {
    let process: ProcessUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).lineLimit(1)
                if !process.command.isEmpty {
                    Text(process.command).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            Text(bytes(Double(process.footprint)))
                .monospacedDigit()
                .foregroundStyle(process.level.color)
                .fontWeight(process.level == .ok ? .regular : .semibold)
        }
        .help("\(process.name) (pid \(process.pid))\n\(process.command)")
        .contextMenu {
            Button("Quit") { kill(process.pid, SIGTERM) }
            Button("Force Quit") { kill(process.pid, SIGKILL) }
            Divider()
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            }
        }
    }
}
