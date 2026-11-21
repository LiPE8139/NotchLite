// fstest — opens a borderless black window covering the display for a few seconds, so the
// island's fullscreen detection can be exercised without a real video.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // "native" switches to a real fullscreen Space, which is where the island used to
        // reappear: the window server re-orders all-Spaces panels when the Space changes.
        let native = CommandLine.arguments.contains("native")
        let window = NSWindow(contentRect: native ? screen.visibleFrame : screen.frame,
                              styleMask: native ? [.titled, .closable, .resizable] : [.borderless],
                              backing: .buffered,
                              defer: false)
        window.level = .normal
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        app.activate(ignoringOtherApps: true)

        if native {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { window.toggleFullScreen(nil) }
        }
        if native {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                let f = window.frame
                print("STATE fullScreen=\(window.styleMask.contains(.fullScreen)) frame=\(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY))")
                fflush(stdout)
            }
        }
        let seconds = Double(CommandLine.arguments.dropFirst().first { $0 != "native" } ?? "6") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
