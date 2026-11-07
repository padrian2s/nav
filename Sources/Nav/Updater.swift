import AppKit

/// Updates Nav from the latest GitHub release: checks, downloads Nav.zip, swaps the app
/// in place and restarts it.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "padrian2s/nav"

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(String)
        case downloading(String)
        case installing
        case failed(String)
    }

    @Published private(set) var status = Status.idle
    /// The newer release's notes, shown under the button.
    @Published private(set) var notes = ""
    private var assetURL: URL?
    private var timer: Timer?
    /// Install as soon as a newer release is found (`open -a Nav --args --update`).
    var installWhenFound = CommandLine.arguments.contains("--update")

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var latestVersion: String? {
        switch status {
        case .available(let v), .downloading(let v): v
        default: nil
        }
    }

    /// Checks now and every 6 hours, quietly.
    func startChecking() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        switch status {
        case .checking, .downloading, .installing: return
        default: break
        }
        status = .checking
        Task { @MainActor in
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { throw UpdateError("No release on GitHub yet.") }
                guard code == 200 else { throw UpdateError("GitHub answered \(code).") }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(version, than: Self.currentVersion) else {
                    status = .upToDate
                    notes = ""
                    return
                }
                guard let asset = release.assets.first(where: { $0.name == "Nav.zip" }) else {
                    throw UpdateError("Release \(release.tag_name) has no Nav.zip.")
                }
                assetURL = asset.url
                notes = release.body ?? ""
                status = .available(version)
                if installWhenFound { install() }
            } catch {
                status = .failed(Self.describe(error))
            }
        }
    }

    /// Downloads the release, replaces this Nav.app with it and restarts.
    func install() {
        guard case .available(let version) = status, let assetURL else { return }
        status = .downloading(version)
        Task { @MainActor in
            do {
                var request = URLRequest(url: assetURL)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                let (zip, response) = try await URLSession.shared.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError("Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
                }
                status = .installing
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nav-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
                let app = dir.appendingPathComponent("Nav.app")
                guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
                    throw UpdateError("The downloaded Nav.zip isn't Nav \(version).")
                }
                relaunch(into: app)
            } catch {
                status = .failed(Self.describe(error))
            }
        }
    }

    /// A shell waits for Nav to quit, puts the new app where this one is, and opens it.
    private func relaunch(into app: URL) {
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1" && mv "$2" "$1" && xattr -dr com.apple.quarantine "$1" 2>/dev/null
        open "$1"
        rm -rf "$(dirname "$2")"
        """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "nav-update", target, app.path]
        do {
            try shell.run()
        } catch {
            status = .failed(Self.describe(error))
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let url: URL   // the API url; with Accept: octet-stream it redirects to the file
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// "0.10.0" > "0.9.3", number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { p in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 { continuation.resume(returning: out) }
                else { continuation.resume(throwing: UpdateError("\((path as NSString).lastPathComponent) failed.")) }
            }
            do { try p.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
