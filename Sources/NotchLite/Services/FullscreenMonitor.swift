import AppKit
import CoreGraphics

/// Watches for another app's window covering the entire display — a fullscreen video, a game,
/// a slideshow — and reports when the island should get out of the way.
///
/// Uses the window list rather than a Space observer: it needs no permissions, and reading
/// bounds is cheap enough to poll once a second. A window only counts when it belongs to the
/// frontmost app and reaches the very top of the display, which is what tells a real fullscreen
/// window apart from an ordinary maximised one (that one stops below the menu bar).
@MainActor
final class FullscreenMonitor {
    /// Fires while something is fullscreen, and once when it stops. The receiver must be
    /// idempotent: it is called on every poll, not just when the state flips.
    var onChange: ((Bool) -> Void)?

    private let panelScreen: () -> NSScreen?
    private var timer: Timer?
    private var isFullscreen = false

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    init(screen: @escaping () -> NSScreen?) {
        panelScreen = screen
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // A generous tolerance lets the system batch this wakeup with others.
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Check right now — used when the active Space changes, so entering fullscreen is handled
    /// immediately instead of on the next tick.
    func checkNow() { check() }

    private func check() {
        let now = Self.coveringAppIsFullscreen(on: panelScreen())
        // Report every tick while fullscreen: the receiver re-asserts the hide, because macOS
        // re-orders the panel when the fullscreen Space becomes active.
        guard now != isFullscreen || now else { return }
        isFullscreen = now
        onChange?(now)
    }

    static func coveringAppIsFullscreen(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ownPID,
              front.activationPolicy == .regular else { return false }

        let display = screen.frame
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }

        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  owner == front.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            // Full screen means it also covers the menu bar strip the island lives in.
            if width >= display.width - 2, height >= display.height - 2 { return true }
        }
        return false
    }
}
