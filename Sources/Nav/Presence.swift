import AppKit
import SwiftUI

/// Whether a window is really on screen. A `TimelineView` keeps ticking, and redrawing, in a
/// window that was closed, ordered out, covered or left on another Space; its views read
/// `\.isShowing` to pause while nobody can see them.
final class WindowPresence: ObservableObject {
    @Published private(set) var isShowing = false
    private var observer: NSObjectProtocol?

    func watch(_ window: NSWindow) {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.update(window.occlusionState.contains(.visible))
        }
        update(window.occlusionState.contains(.visible))
    }

    private func update(_ showing: Bool) {
        if showing != isShowing { isShowing = showing }
    }
}

private struct IsShowingKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the view's window is not visible: animations should stop.
    var isShowing: Bool {
        get { self[IsShowingKey.self] }
        set { self[IsShowingKey.self] = newValue }
    }
}

/// The root of a window's SwiftUI content: hands `presence` down as `\.isShowing`.
struct Presented<Content: View>: View {
    @ObservedObject var presence: WindowPresence
    let content: Content

    init(_ presence: WindowPresence, @ViewBuilder content: () -> Content) {
        self.presence = presence
        self.content = content()
    }

    var body: some View {
        content.environment(\.isShowing, presence.isShowing)
    }
}
