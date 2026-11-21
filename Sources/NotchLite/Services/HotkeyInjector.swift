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

        static let controlOptionP = Bindings(playPause: 35, previous: 123, next: 124)
    }

    private static let modifiers: CGEventFlags = [.maskControl, .maskAlternate]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show the Accessibility prompt (only the first time it is needed).
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func playPause(_ bindings: Bindings) { press(bindings.playPause) }
    static func previous(_ bindings: Bindings) { press(bindings.previous) }
    static func next(_ bindings: Bindings) { press(bindings.next) }

    private static func press(_ key: CGKeyCode) {
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
