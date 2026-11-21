import AppKit
import ApplicationServices

/// Drives players that have no scripting dictionary by pressing *their own* global hotkeys.
///
/// MediaRemote only accepts commands for the elected player, and NetEase exposes no scripting
/// interface, so posting the keys it registered is the remaining route. Needs Accessibility trust:
/// synthetic events from an untrusted process are silently dropped by the system.
enum HotkeyInjector {
    /// Keys we press for players that only listen to their own shortcuts.
    struct Bindings {
        let playPause: CGKeyCode
        let previous: CGKeyCode
        let next: CGKeyCode

        /// NetEase's global shortcuts as configured by the user: ⌃⌥⌘S, ⌃⌥⌘A, ⌃⌥⌘D.
        /// Key codes: S = 1, A = 0, D = 2.
        static let netEase = Bindings(playPause: 1, previous: 0, next: 2)
    }

    private static let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show the Accessibility prompt (only the first time it is needed).
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func playPause(_ bindings: Bindings) { press(bindings.playPause) }
    static func previous(_ bindings: Bindings) { press(bindings.previous) }
    static func next(_ bindings: Bindings) { press(bindings.next) }

    /// Temporary diagnostic: records what the hotkey path actually saw.
    private static func trace(_ line: String) {
        let data = (line + "\n").data(using: .utf8)!
        let url = URL(fileURLWithPath: "/tmp/notchlite-hotkey.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    private static func press(_ key: CGKeyCode) {
        trace("press key=\(key) trusted=\(isTrusted)")
        guard isTrusted else {
            NSLog("[Hotkey] accessibility not granted; cannot drive the player")
            requestTrust()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = modifiers
            event.post(tap: .cghidEventTap)
        }
    }
}
