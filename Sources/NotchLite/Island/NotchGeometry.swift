import AppKit

enum NotchGeometry {
    /// The built-in display if it has a notch, otherwise the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// Size of the physical notch. Screens without one get a fake notch the height of the menu bar.
    static func notchSize(for screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return CGSize(width: width, height: screen.safeAreaInsets.top)
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 190, height: max(24, menuBarHeight))
    }
}

enum Metrics {
    /// Width of each "wing" beside the notch in the compact live-activity state.
    static let wing: CGFloat = 36
    /// Wing width while the hover controls are showing: room for three buttons.
    static let controlsWing: CGFloat = 76
    /// Inner margin inside each wing: the cover sits this far from the island's outer edge.
    static let wingInset: CGFloat = 10
    /// How far the compact island's rounded shoulders reach past the notch on each side.
    static let compactTopRadius: CGFloat = 4
    static let expandedTopRadius: CGFloat = 14
    /// Width of the expanded island: room for the tabs and the gear beside the camera, no more.
    static let expandedWidth: CGFloat = 440
    /// How much wider than the notch the expanded island must stay for the header to fit.
    static let expandedBleed: CGFloat = 200
    static let expandedContentHeight: CGFloat = 152
    /// Banner peeks: label font, icon column and the room the battery badge needs on the right.
    static let peekFontSize: CGFloat = 13
    static let peekIconWidth: CGFloat = 16
    static let peekIconSpacing: CGFloat = 5
    static let peekTrailingWidth: CGFloat = 70
    /// Transparent margin around the largest island so its shadow is not clipped.
    static let windowPadding: CGFloat = 40

    /// Size of the island in the expanded state.
    static func expandedSize(notch: CGSize) -> CGSize {
        CGSize(width: max(expandedWidth, notch.width + expandedBleed),
               height: notch.height + expandedContentHeight)
    }

    static func windowSize(notch: CGSize) -> CGSize {
        CGSize(width: expandedSize(notch: notch).width + windowPadding * 2,
               height: notch.height + expandedContentHeight + windowPadding)
    }
}
