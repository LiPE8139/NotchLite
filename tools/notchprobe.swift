// notchprobe <center|wing-left|wing-right|below|away>
// Prints the notch geometry, then warps the cursor to a probe point so the island's
// hover logic can be exercised from a shell.
import AppKit
import CoreGraphics

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "center"

guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
    print("no screen")
    exit(1)
}

let notch: CGSize = {
    if screen.safeAreaInsets.top > 0,
       let left = screen.auxiliaryTopLeftArea,
       let right = screen.auxiliaryTopRightArea {
        return CGSize(width: screen.frame.width - left.width - right.width,
                      height: screen.safeAreaInsets.top)
    }
    return CGSize(width: 190, height: 24)
}()

let midX = screen.frame.midX
let top = screen.frame.maxY
// Wings are 38pt wide, plus the 6pt rounded flare the island adds on each side.
let wing = CGFloat(38) + 6

let point: CGPoint
switch arg {
case "center":     point = CGPoint(x: midX, y: top - notch.height / 2)
case "wing-left":  point = CGPoint(x: midX - notch.width / 2 - wing / 2, y: top - notch.height / 2)
case "wing-right": point = CGPoint(x: midX + notch.width / 2 + wing / 2, y: top - notch.height / 2)
case "below":      point = CGPoint(x: midX, y: top - notch.height - 30)
case "away":       point = CGPoint(x: midX, y: top - 400)
default:
    print("usage: notchprobe <center|wing-left|wing-right|below|away>")
    exit(2)
}

print(String(format: "notch=%.1fx%.1f at midX=%.1f  wing=%.1f  → warping to (%.1f, %.1f)",
             notch.width, notch.height, midX, wing, point.x, point.y))

// A warp alone does not generate an event, and the island listens for real mouse moves.
func move(to p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: p, mouseButton: .left) {
        event.post(tap: .cghidEventTap)
    }
}

// Approach in small steps, the way a cursor actually travels, so the app sees a move.
let start = CGEvent(source: nil)?.location ?? point
for step in 1...6 {
    let t = CGFloat(step) / 6
    move(to: CGPoint(x: start.x + (point.x - start.x) * t,
                     y: start.y + (point.y - start.y) * t))
    usleep(20_000)
}
move(to: CGPoint(x: point.x + 1, y: point.y))
usleep(30_000)
move(to: point)
