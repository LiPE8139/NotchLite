// windowprobe — lists on-screen windows that cover the whole display, without Screen Recording.
// Verifies that CGWindowListCopyWindowInfo is usable for fullscreen detection.
import AppKit
import CoreGraphics

guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
    print("no screen"); exit(1)
}
let frame = screen.frame
let front = NSWorkspace.shared.frontmostApplication
print("screen=\(Int(frame.width))x\(Int(frame.height))  frontmost=\(front?.localizedName ?? "?") (\(front?.processIdentifier ?? -1))")

guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("CGWindowList returned nothing"); exit(1)
}

print("windows on screen: \(windows.count)")
for w in windows {
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let width = b["Width"] ?? 0, height = b["Height"] ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? -1
    let name = w[kCGWindowOwnerName as String] as? String ?? "?"
    // Only whole-display windows at the normal layer are interesting.
    guard width >= frame.width * 0.95, height >= frame.height * 0.9 else { continue }
    print(String(format: "  pid=%d layer=%d  %.0fx%.0f  %@  %@",
                 owner, layer, width, height, name,
                 owner == front?.processIdentifier ? "← frontmost" : ""))
}

// Every window the island owns, whether or not it is on screen right now.
print("NotchLite windows (owner name):")
for w in windows where (w[kCGWindowOwnerName as String] as? String) == "NotchLite" {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    print(String(format: "  layer=%d  %.0fx%.0f at (%.0f,%.0f)", layer,
                 b["Width"] ?? 0, b["Height"] ?? 0, b["X"] ?? 0, b["Y"] ?? 0))
}
