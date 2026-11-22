import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Owns the panel and decides when the island expands, collapses and accepts clicks.
@MainActor
final class NotchController {
    let model = IslandModel()

    private let panel = NotchPanel()
    private var screen: NSScreen?
    private var monitors: [Any] = []

    private var hoverTask: Task<Void, Never>?
    private var hoverControlsTask: Task<Void, Never>?
    private var shelfHotKey: HotKey?
    private var pasteHotKey: HotKey?
    private var isMenuOpen = false
    /// Opened with a shortcut: stays open until the pointer visits the island, or a few seconds pass.
    private var openedByKeyboard = false
    private var keyboardOpenTask: Task<Void, Never>?
    private lazy var dropZone = DropZoneController(shelf: model.shelf)
    /// Set while another app owns the screen (a fullscreen video): the island steps aside.
    private var isHiddenForFullscreen = false
    /// Set when the shelf was opened by a drag; it then stays open until the mouse is released.
    private var expandedForDrag = false
    private lazy var fullscreen = FullscreenMonitor { [weak self] in self?.screen }
    private var shake = ShakeDetector()
    private var shakeCooldownUntil: TimeInterval = 0
    /// Change count of the drag pasteboard when the button went down: a shake only counts if a new drag started since.
    private var pressDragChangeCount = 0

    private var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }

    /// Shaking a dragged file opens a drop zone beside the cursor.
    private var shakeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "shakeToShelf") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shakeToShelf") }
    }

    func start() {
        let hosting = DropHostingView(rootView: IslandRootView(model: model))
        hosting.sizingOptions = []
        hosting.targetSize = { [weak self] in self?.model.islandSize ?? .zero }
        hosting.onTargetChange = { [weak self] targeted in
            guard let model = self?.model else { return }
            model.isDropTargeted = targeted
            if targeted { model.tab = .shelf }
        }
        hosting.onDrop = { [weak self] pasteboard in
            (self?.model.shelf.addFromPasteboard(pasteboard) ?? 0) > 0
        }
        panel.contentView = hosting
        panel.keyPolicy = { false }
        panel.onEscape = { [weak self] in self?.collapse() }
        model.onOpenSettings = { [weak self] in self?.showSettingsMenu() }
        model.onTapExpand = { [weak self] in
            guard let self, !self.model.isExpanded else { return }
            self.expand()
        }

        layout()
        panel.orderFrontRegardless()

        installMouseMonitors()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.media.stop() }
        }

        // ⌃⌥D opens or closes the shelf, ⌃⌥V puts the clipboard on it.
        shelfHotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey, id: 2) { [weak self] in
            MainActor.assumeIsolated { self?.toggleShelf() }
        }
        pasteHotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey, id: 3) { [weak self] in
            MainActor.assumeIsolated { _ = self?.model.shelf.addFromPasteboard() }
        }

        // Menus and drags out of the shelf must not be interrupted by the island collapsing.
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.isMenuOpen = open
                    if !open { self?.handleMouse() }
                }
            }
        }

        fullscreen.onChange = { [weak self] hidden in self?.setHiddenForFullscreen(hidden) }
        fullscreen.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullscreen.checkNow() }
        }

        model.startServices()
        enableLaunchAtLoginOnce()
        #if DEBUG
        installDebugHook()
        #endif
    }

    #if DEBUG
    private var debugPinned = false

    /// Drive the island from a shell for screenshots:
    /// `notifyutil`-style via DistributedNotificationCenter, name `com.example.notchlite.debug`,
    /// object `expand:<tab>` | `collapse` | `peek:<track>` | `media:<json file>` |
    /// `shelf-add:<path>` | `shelf-paste` | `shelf-select[:<name part>]` |
    /// `shelf-clear` | `shelf-zip` | `shelf-dump:<file>` | `state:<file>` | `dropzone`.
    private func installDebugHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.example.notchlite.debug"), object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { self?.runDebug(command) }
        }
    }

    private func runDebug(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "expand":
            debugPinned = true
            expand(tab: ExpandedTab(rawValue: arg) ?? .home)
        case "collapse":
            debugPinned = false
            collapse()
        case "peek":
            if arg == "track" { model.showPeek(.nowPlaying, seconds: 6) }
        case "media":
            if let data = FileManager.default.contents(atPath: arg) { model.media.debugConsume(data) }
        case "shelf-add":
            model.shelf.add([.file(URL(fileURLWithPath: arg))])
        case "shelf-paste":
            _ = model.shelf.addFromPasteboard()
        case "shelf-select":
            let names = arg.split(separator: ",").map(String.init)
            model.shelf.selection = Set(model.shelf.items.filter { item in
                names.isEmpty || names.contains { item.url.lastPathComponent.contains($0) }
            }.map(\.id))
        case "shelf-clear":
            model.shelf.remove(Set(model.shelf.items.map(\.id)))
        case "shelf-zip":
            model.shelf.zip(model.shelf.targets)
        case "shelf-dump":
            let lines = model.shelf.items.map { "\($0.url.path)\t\($0.isOwned ? "owned" : "ref")\t\(model.shelf.selection.contains($0.id) ? "sel" : "-")" }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "state":
            let text = "expanded=\(model.isExpanded) menuOpen=\(model.isMenuOpen) draggingOut=\(model.isDraggingOut) targeted=\(model.isDropTargeted)"
            try? text.write(toFile: arg, atomically: true, encoding: .utf8)
        case "dropzone":
            dropZone.show(near: NSEvent.mouseLocation)
        default:
            break
        }
    }
    #endif

    private func layout() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        self.screen = screen
        model.notchSize = NotchGeometry.notchSize(for: screen)
        let size = Metrics.windowSize(notch: model.notchSize)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }

    // MARK: - Mouse

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask.union(.leftMouseDown), handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.trackShake(event)
                if event.type != .leftMouseDown { self?.handleMouse() }
            }
        }) { monitors.append(global) }
        // The source strip scrolls from here rather than from SwiftUI: a ScrollView in this
        // non-activating panel ignored the trackpad.
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, self.model.isExpanded, !self.isMenuOpen else { return event }
            // SwiftUI reports frames top-left origin; the event comes bottom-left origin.
            let height = self.panel.contentView?.bounds.height ?? 0
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            guard self.model.stripFrame.insetBy(dx: -6, dy: -6).contains(point) else { return event }
            let delta = event.scrollingDeltaX
            guard delta != 0 else { return event }
            self.model.stripScroll = min(0, max(-self.model.stripMaxScroll,
                                                self.model.stripScroll + delta))
            return nil
        }) {
            monitors.append(scroll)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse() }
            return event
        }) { monitors.append(local) }
    }

    /// Watches other apps' drags for a shake. The drag pasteboard is only read once a shake is seen.
    private func trackShake(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressDragChangeCount = NSPasteboard(name: .drag).changeCount
            shake.reset()
        case .leftMouseDragged:
            guard shakeEnabled, event.timestamp > shakeCooldownUntil, !dropZone.isVisible,
                  shake.feed(x: NSEvent.mouseLocation.x, at: event.timestamp) else { return }
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != pressDragChangeCount,
                  pasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) else { return }
            shakeCooldownUntil = event.timestamp + 1.5
            dropZone.show(near: NSEvent.mouseLocation)
        default:
            break
        }
    }

    /// Island frame in screen coordinates for the current presentation.
    private func islandRect() -> NSRect {
        guard let screen else { return .zero }
        let size = model.islandSize
        let sides = model.islandSides
        // The notch stays centred; the island may reach further on one side.
        return NSRect(x: screen.frame.midX - model.notchSize.width / 2 - sides.leading,
                      y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height + 2)
    }

    /// Frame of the physical notch, ignoring the wings and the peek banner.
    ///
    /// Those sit on top of the menu bar, so they must never be a hover trigger: reaching for a
    /// menu bar icon beside the notch would otherwise open the island and swallow the click.
    private func notchRect() -> NSRect {
        guard let screen else { return .zero }
        let size = model.notchSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func handleMouse() {
        guard !isHiddenForFullscreen else { return }
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons & 1 == 0 { expandedForDrag = false }

        guard model.isExpanded else {
            handleCollapsedMouse(mouse, on: screen)
            return
        }

        let island = islandRect()
        let inside = island.insetBy(dx: -14, dy: -14).contains(mouse)

        // Clicks outside the island fall through to whatever is underneath.
        let ignoresMouse = !island.contains(mouse)
        if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }

        if inside {
            hoverTask?.cancel()
            hoverTask = nil
        } else {
            guard hoverTask == nil, !keepsOpen else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, let self else { return }
                self.hoverTask = nil
                if !self.keepsOpen { self.collapse() }
            }
        }
    }

    /// Collapsed: hovering the notch or the waveform wing reveals the transport controls, and a
    /// click on the notch opens the island.
    ///
    /// Both sit on top of menu bar items, so the panel is only armed once the controls are
    /// actually showing — a quick click on an icon underneath still passes straight through.
    private func handleCollapsedMouse(_ mouse: NSPoint, on screen: NSScreen) {
        if mouse.y < screen.frame.maxY - 120 {
            hideHoverControls()
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }

        let overNotch = notchRect().insetBy(dx: -2, dy: -10).contains(mouse)
        let overWaveform = model.canShowWings && waveformRect().contains(mouse)
        // Once shown, the controls stay reachable from anywhere on the island.
        let overControls = model.isHovering && islandRect().insetBy(dx: 0, dy: -4).contains(mouse)

        if overNotch {
            if openedByKeyboard { releaseKeyboardOpen() }
            startHoverControlsDwell()
        } else if overWaveform {
            startHoverControlsDwell()
        } else if !overControls {
            hideHoverControls()
        }

        // Arm the panel only where a click should reach us: the notch, or the controls themselves.
        let interactive = overNotch || overControls
        if panel.ignoresMouseEvents != !interactive { panel.ignoresMouseEvents = !interactive }

        // Dragging a file onto the notch opens the shelf. The trigger stays the notch itself — a
        // wider one popped open for every drag that happened to pass nearby — but once it fires the
        // shelf stays put until the mouse is released, so carrying the file in is not a balancing act.
        if overNotch, NSEvent.pressedMouseButtons & 1 != 0, isCarryingDragPayload {
            expandedForDrag = true
            // If fullscreen hiding parked the panel, bring it back for the drop.
            if isHiddenForFullscreen { setHiddenForFullscreen(false) }
            hideHoverControls()
            expand(tab: .shelf)
        }
    }

    /// A short dwell keeps the wings from flinching as the pointer sweeps past the notch.
    private func startHoverControlsDwell() {
        guard model.canShowWings, !model.isHovering, hoverControlsTask == nil else { return }
        hoverControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.hoverControlsTask = nil
            self.model.isHovering = true
            // Re-arm right away: the wings just widened, and the pointer has not moved since.
            self.handleMouse()
        }
    }

    private func hideHoverControls() {
        hoverControlsTask?.cancel()
        hoverControlsTask = nil
        if model.isHovering { model.isHovering = false }
    }

    /// True when the pointer is carrying something the shelf could accept: the drag pasteboard has
    /// been filled since this mouse-down.
    private var isCarryingDragPayload: Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != pressDragChangeCount else { return false }
        return pasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self, NSString.self], options: nil)
    }

    /// The trailing wing — the side the waveform and the transport controls live on.
    private func waveformRect() -> NSRect {
        let island = islandRect()
        let notch = notchRect()
        return NSRect(x: notch.maxX, y: island.minY,
                      width: max(0, island.maxX - notch.maxX), height: island.height)
    }

    /// Typing a note or using the settings menu should not be interrupted by the mouse drifting away.
    private var keepsOpen: Bool {
        #if DEBUG
        if debugPinned { return true }
        #endif
        if expandedForDrag && NSEvent.pressedMouseButtons & 1 != 0 { return true }
        return openedByKeyboard || isMenuOpen || model.isMenuOpen || model.isDraggingOut || model.isDropTargeted
    }

    func expand(tab: ExpandedTab? = nil) {
        if let tab { model.tab = tab }
        hideHoverControls()
        model.clearPeek()
        model.isExpanded = true
        if hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        handleMouse()
    }

    func collapse() {
        // Picking another player is only meant to change what the open panel shows. Once it closes
        // the notch goes back to following whatever is actually playing.
        model.media.followSystem()
        releaseKeyboardOpen()
        hoverTask?.cancel()
        hoverTask = nil
        model.isExpanded = false
        if panel.isKeyWindow {
            // Hand keyboard focus back to the app the user was in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = true
    }

    /// Another app went fullscreen (video, game, slideshow): get out of its way, and come back
    /// when it leaves. The physical notch stays black either way.
    private func setHiddenForFullscreen(_ hidden: Bool) {
        // A drag is in progress: never take the panel away from under the file being carried.
        // Fullscreen detection can also misfire on the window that started the drag.
        if hidden, NSEvent.pressedMouseButtons & 1 != 0 { return }
        if hidden {
            if !isHiddenForFullscreen {
                isHiddenForFullscreen = true
                hoverTask?.cancel()
                hoverTask = nil
                model.clearPeek()
                collapse()
            }
            // Re-asserted on every poll: entering fullscreen swaps in a new Space, and the window
            // server re-orders the panel (which joins all Spaces) back onto the screen.
            if panel.isVisible { panel.orderOut(nil) }
        } else if isHiddenForFullscreen {
            isHiddenForFullscreen = false
            panel.orderFrontRegardless()
            handleMouse()
        }
    }

    private func toggleShelf() {
        if model.isExpanded && model.tab == .shelf {
            collapse()
            return
        }
        // Set before expanding, or the pointer being elsewhere would collapse it straight away.
        openedByKeyboard = true
        keyboardOpenTask?.cancel()
        keyboardOpenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.releaseKeyboardOpen()
            self?.handleMouse()
        }
        expand(tab: .shelf)
    }

    private func releaseKeyboardOpen() {
        openedByKeyboard = false
        keyboardOpenTask?.cancel()
        keyboardOpenTask = nil
    }

    // MARK: - Settings

    private func showSettingsMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: String(localized: "About NotchLite"),
                                action: #selector(MenuTarget.showAbout), keyEquivalent: ""))
        menu.addItem(.separator())

        let haptics = NSMenuItem(title: String(localized: "Haptic feedback"), action: #selector(MenuTarget.toggleHaptics), keyEquivalent: "")
        haptics.state = hapticsEnabled ? .on : .off
        menu.addItem(haptics)

        let shake = NSMenuItem(title: String(localized: "Shake a dragged file to open drop zone"), action: #selector(MenuTarget.toggleShake), keyEquivalent: "")
        shake.state = shakeEnabled ? .on : .off
        menu.addItem(shake)

        let removeAfterDrag = NSMenuItem(title: String(localized: "Remove from shelf after dragging out"), action: #selector(MenuTarget.toggleRemoveAfterDrag), keyEquivalent: "")
        removeAfterDrag.state = model.shelf.removesAfterDrag ? .on : .off
        menu.addItem(removeAfterDrag)

        let login = NSMenuItem(title: String(localized: "Launch at login"), action: #selector(MenuTarget.toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit NotchLite"), action: #selector(MenuTarget.quit), keyEquivalent: "q"))

        let target = MenuTarget(controller: self)
        menu.items.forEach { $0.target = target }

        isMenuOpen = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        isMenuOpen = false
        withExtendedLifetime(target) {}
        handleMouse()
    }

    fileprivate func toggleHaptics() { hapticsEnabled.toggle() }
    fileprivate func toggleShake() { shakeEnabled.toggle() }
    fileprivate func toggleRemoveAfterDrag() { model.shelf.removesAfterDrag.toggle() }

    /// The first launch from /Applications turns on start-at-login; the ⚙️ menu can turn it off.
    private func enableLaunchAtLoginOnce() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("[Settings] launch at login failed: \(error)")
        }
    }

    fileprivate func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[Settings] launch at login failed: \(error)")
        }
    }

}

/// NSMenu needs an Objective-C target for its actions.
private final class MenuTarget: NSObject {
    weak var controller: NotchController?

    init(controller: NotchController) { self.controller = controller }

    @objc func showAbout() {
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
    }

    @objc func toggleHaptics() { MainActor.assumeIsolated { controller?.toggleHaptics() } }
    @objc func toggleShake() { MainActor.assumeIsolated { controller?.toggleShake() } }
    @objc func toggleRemoveAfterDrag() { MainActor.assumeIsolated { controller?.toggleRemoveAfterDrag() } }
    @objc func toggleLogin() { MainActor.assumeIsolated { controller?.toggleLogin() } }
    @objc func quit() { NSApp.terminate(nil) }
}
