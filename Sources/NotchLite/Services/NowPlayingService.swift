import AppKit
import Foundation
import SwiftUI

/// One concurrent Now Playing session, as reported by the MediaRemote bridge.
///
/// Several of these can exist at once — a song in Music and a video in a browser — which is what
/// the system's own Now Playing panel shows.
struct MediaSource: Identifiable, Equatable {
    let bundleID: String
    let displayName: String
    let pid: Int32
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var rate: Double
    var isPlaying: Bool
    /// The session the system currently routes transport commands to.
    var isActive: Bool
    /// When the bridge reported this snapshot; elapsed is extrapolated from here.
    var reportedAt: Date

    var id: String { bundleID }

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying, rate > 0 else { return max(0, min(elapsed, duration > 0 ? duration : elapsed)) }
        let projected = elapsed + date.timeIntervalSince(reportedAt) * rate
        return duration > 0 ? min(max(projected, 0), duration) : max(projected, 0)
    }
}

/// Streams every Now Playing session through the MediaRemote bridge and tracks which one the
/// island is showing.
///
/// Since macOS 15.4 MediaRemote refuses non-Apple callers, so the bridge is a dylib loaded by
/// `/usr/bin/perl`: same trick the previous single-session adapter used, but reading the
/// multi-session API.
@Observable @MainActor
final class NowPlayingService {
    private(set) var sources: [MediaSource] = []
    /// Nil follows whatever the system considers active.
    private(set) var selectedID: String?
    private(set) var isAvailable = true
    private(set) var showsActivity = false

    @ObservationIgnored var onTrackChange: (() -> Void)?

    @ObservationIgnored private var process: Process?
    /// The bridge's stdin: `{"bundle":"…","cmd":N}` addresses one session directly.
    @ObservationIgnored private var commandPipe: Pipe?
    @ObservationIgnored private var lineBuffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var hideActivityTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackKey = ""
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var accents: [String: Color] = [:]
    /// Last artwork seen for each player. Only the active session is ever re-read; the rest keep
    /// whatever they last had, which is what makes switching back feel instant.
    ///
    /// Deliberately observed (no `@ObservationIgnored`): storing a freshly fetched cover has to
    /// invalidate the views, otherwise they stay on the icon fallback forever.
    private var artworkCache: [String: NSImage] = [:]
    private var artworkAccent: [String: Color] = [:]
    @ObservationIgnored private var artworkKey: [String: String] = [:]
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// A track that asked for artwork while a fetch was already running.
    @ObservationIgnored private var pendingArtwork: MediaSource?
    @ObservationIgnored private var lastActiveID: String?

    var selected: MediaSource? {
        if let selectedID, let match = sources.first(where: { $0.id == selectedID }) { return match }
        return sources.first
    }

    // MARK: - What the views read

    var title: String {
        guard let selected else { return "" }
        return selected.title.isEmpty ? selected.displayName : selected.title
    }
    var artist: String { selected?.artist ?? "" }
    var album: String { selected?.album ?? "" }
    var duration: TimeInterval { selected?.duration ?? 0 }
    var isPlaying: Bool { selected?.isPlaying ?? false }
    var hasMedia: Bool { selected != nil }
    var bundleID: String? { selected?.bundleID }
    var displayName: String { selected?.displayName ?? "" }

    /// Whether the transport should be offered: scriptable players always, the rest only while they
    /// hold the system's playback slot (MediaRemote drops commands for anything else).
    var canControl: Bool { canScript || canUseHotkeys || (selected?.isActive ?? false) }

    /// Cached artwork for this player, or its icon when the player never offered any (video
    /// sources have none, and that is fine).
    var artwork: NSImage? {
        guard let selected else { return nil }
        return artworkCache[selected.bundleID] ?? icon(for: selected.bundleID)
    }

    var playerIcon: NSImage? { selected.map { icon(for: $0.bundleID) } }

    var accent: Color {
        guard let bundle = selected?.bundleID else { return .white }
        return artworkAccent[bundle] ?? accents[bundle] ?? .white
    }

    func elapsed(at date: Date) -> TimeInterval { selected?.elapsed(at: date) ?? 0 }

    /// Player icon, also used by the session switcher in the header.
    func icon(for bundle: String) -> NSImage {
        if let cached = icons[bundle] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage()
        }
        icons[bundle] = image
        accents[bundle] = Color(nsColor: image.vibrantAverageColor ?? .white)
        return image
    }

    // MARK: - Switching sessions

    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        guard sources.count > 1 else { return }
        let current = sources.firstIndex { $0.id == (selected?.id ?? "") } ?? 0
        let next = (current + delta + sources.count) % sources.count
        pinned = true
        selectedID = sources[next].id
        lastTrackKey = trackKey(of: sources[next])
        updateActivity()
    }

    func select(_ id: String) {
        guard let match = sources.first(where: { $0.id == id }) else { return }
        pinned = true
        selectedID = id
        lastTrackKey = trackKey(of: match)
        updateActivity()
    }

    /// Back to following the system's active session.
    func followSystem() {
        pinned = false
        selectedID = nil
        updateActivity()
    }

    // MARK: - Lifecycle

    func start() {
        // Ask once so the app lands in System Settings → Accessibility; the toggle itself can only
        // be flipped by hand, so surface it early instead of waiting for a failed button press.
        let prompted = UserDefaults.standard.bool(forKey: "askedForAccessibility")
        if !HotkeyInjector.isTrusted && !prompted {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            HotkeyInjector.requestTrust()
        }
        guard let launch = Self.launchConfiguration() else {
            isAvailable = false
            NSLog("[NowPlaying] MediaRemote bridge not found; Now Playing disabled")
            return
        }
        killOrphaned()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [launch.script.path, launch.library.path, "bridge_stream"]
        let pipe = Pipe()
        let commands = Pipe()
        process.standardOutput = pipe
        process.standardInput = commands
        process.standardError = FileHandle.nullDevice
        self.commandPipe = commands
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.bridgeExited(status: proc.terminationStatus, reason: proc.terminationReason) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            isAvailable = false
            NSLog("[NowPlaying] failed to launch bridge: \(error)")
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        commandPipe = nil
    }

    private func killOrphaned() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", "bridge.pl"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func bridgeExited(status: Int32, reason: Process.TerminationReason) {
        process = nil
        if reason == .exit && status != 0 {
            isAvailable = false
            return
        }
        guard restarts < 5 else { isAvailable = false; return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    // MARK: - Bridge output

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let raw = json["sources"] as? [[String: Any]] else { continue }
            ingest(raw)
        }
    }

    private func ingest(_ raw: [[String: Any]]) {
        let now = Date()
        var parsed: [MediaSource] = []
        for item in raw {
            guard let bundle = item["bundle"] as? String, !bundle.isEmpty else { continue }
            let title = item["title"] as? String ?? ""
            parsed.append(MediaSource(
                bundleID: bundle,
                displayName: item["name"] as? String ?? bundle,
                pid: Int32(item["pid"] as? Int ?? 0),
                title: title,
                artist: item["artist"] as? String ?? "",
                album: item["album"] as? String ?? "",
                duration: item["duration"] as? Double ?? 0,
                elapsed: item["elapsed"] as? Double ?? 0,
                rate: item["rate"] as? Double ?? 0,
                isPlaying: item["playing"] as? Bool ?? false,
                isActive: item["active"] as? Bool ?? false,
                reportedAt: now))
        }

        // The session the system is driving leads the list, like the system's own panel.
        parsed.sort { a, b in a.isActive == b.isActive ? false : a.isActive }

        let previousKey = lastTrackKey
        sources = parsed

        if !pinned || !parsed.contains(where: { $0.id == selectedID }) {
            if let active = parsed.first(where: { $0.isActive }) {
                selectedID = active.id
            } else if let current = selectedID, parsed.contains(where: { $0.id == current }) {
                // keep the current pick while it is still around
            } else {
                selectedID = parsed.first?.id
            }
            if !parsed.contains(where: { $0.id == selectedID }) { pinned = false }
        }

        lastTrackKey = trackKey(of: selected)
        updateActivity()

        if let active = parsed.first(where: { $0.isActive }) {
            // Re-entering the active slot is a good moment to re-read its artwork.
            if lastActiveID != active.id { artworkKey[active.id] = nil }
            lastActiveID = active.id
            refreshArtwork(for: active)
        } else {
            lastActiveID = nil
        }

        if lastTrackKey != previousKey, !lastTrackKey.isEmpty, isPlaying {
            onTrackChange?()
        }
    }

    /// Artwork is only pulled for the session the system is driving: the single-session API is the
    /// one that exposes it, and the others keep their previous image until they become active.
    private func refreshArtwork(for source: MediaSource) {
        let key = "\(source.title)|\(source.artist)"
        guard artworkKey[source.bundleID] != key else { return }
        // Skipping tracks quickly must not drop the new track's request.
        guard artworkTask == nil else { pendingArtwork = source; return }
        artworkTask = Task { [weak self] in
            // Players publish the cover a moment after the metadata, so the first read often comes
            // back empty. Retry briefly before giving up until the next track.
            for attempt in 1...4 {
                if let loaded = await Self.loadActiveArtwork() {
                    self?.store(artwork: loaded.image, for: loaded.bundle)
                    self?.artworkKey[source.bundleID] = key
                    break
                }
                if attempt < 4 { try? await Task.sleep(for: .milliseconds(450)) }
            }
            guard let self else { return }
            if self.artworkKey[source.bundleID] != key {
                self.artworkKey[source.bundleID] = key
            }
            self.artworkTask = nil
            if let next = self.pendingArtwork {
                self.pendingArtwork = nil
                self.refreshArtwork(for: next)
            }
        }
    }

    private func store(artwork image: NSImage, for bundle: String) {
        var covers = artworkCache
        covers[bundle] = image
        artworkCache = covers
        if let tint = image.vibrantAverageColor {
            var tints = artworkAccent
            tints[bundle] = Color(nsColor: tint)
            artworkAccent = tints
        }
    }

    /// One-shot read of the active session's artwork through the single-session adapter.
    private static func loadActiveArtwork() async -> (bundle: String, image: NSImage)? {
        guard let paths = AdapterPaths.locate() else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [paths.script.path, paths.framework.path, "get"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let bundle = json["bundleIdentifier"] as? String,
                      let base64 = json["artworkData"] as? String,
                      let raw = Data(base64Encoded: base64),
                      let image = thumbnail(from: raw, maxPixelSize: 256)
                else { continuation.resume(returning: nil); return }
                continuation.resume(returning: (bundle, image))
            }
        }
    }

    private nonisolated static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func trackKey(of source: MediaSource?) -> String {
        guard let source else { return "" }
        return "\(source.bundleID)|\(source.title)|\(source.artist)"
    }

    private func updateActivity() {
        hideActivityTask?.cancel()
        hideActivityTask = nil
        if isPlaying && hasMedia {
            showsActivity = true
        } else if showsActivity {
            hideActivityTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.showsActivity = false
            }
        }
    }

    // MARK: - Transport

    /// Players with a scripting dictionary are driven through AppleScript instead: that talks to the
    /// app directly, so it works even while another app owns the system's playback slot, which is
    /// what limits MediaRemote commands.
    private static let scriptableBundles: Set<String> = ["com.apple.Music", "com.spotify.client"]

    var canScript: Bool {
        guard let bundle = selected?.bundleID else { return false }
        return Self.scriptableBundles.contains(bundle)
    }

    /// Players that expose neither MediaRemote command rights nor a scripting dictionary, but do
    /// register global hotkeys we can press.
    private static let hotkeyBundles: Set<String> = ["com.netease.163music"]

    var canUseHotkeys: Bool {
        guard let bundle = selected?.bundleID else { return false }
        return Self.hotkeyBundles.contains(bundle)
    }


    func togglePlayPause() {
        guard let bundle = selected?.bundleID else { return }
        if Self.scriptableBundles.contains(bundle) {
            runScript(bundle, isPlaying ? "pause" : "play")
        } else if selected?.isActive == true {
            // Only an elected player accepts MediaRemote commands; otherwise fall through.
            send(isPlaying ? 1 : 0, to: bundle)
        } else if Self.hotkeyBundles.contains(bundle) {
            HotkeyInjector.playPause(.netEase)
        }
        updateActivity()
    }

    func next() {
        guard let bundle = selected?.bundleID else { return }
        if Self.scriptableBundles.contains(bundle) {
            runScript(bundle, "next track")
        } else if selected?.isActive == true {
            send(4, to: bundle)
        } else if Self.hotkeyBundles.contains(bundle) {
            HotkeyInjector.next(.netEase)
        }
    }

    func previous() {
        guard let bundle = selected?.bundleID else { return }
        if Self.scriptableBundles.contains(bundle) {
            runScript(bundle, "previous track")
        } else if selected?.isActive == true {
            send(5, to: bundle)
        } else if Self.hotkeyBundles.contains(bundle) {
            HotkeyInjector.previous(.netEase)
        }
    }

    /// Sends one AppleScript command to the player, off the main thread.
    private func runScript(_ bundle: String, _ command: String) {
        let appName = bundle == "com.apple.Music" ? "Music" : "Spotify"
        let source = "tell application \"\(appName)\" to \(command)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("[NowPlaying] apple script failed: \(error)") }
        }
    }

    /// Seeking has no per-session API, so it only applies to the session the system is driving.
    func seek(to seconds: TimeInterval) {
        guard canControl, let adapter = Self.adapterPaths() else { return }
        runAdapter(adapter, ["seek", String(Int(seconds * 1_000_000))])
    }

    private func send(_ command: Int, to bundle: String) {
        guard let handle = commandPipe?.fileHandleForWriting else { return }
        let line = "{\"bundle\":\"\(bundle)\",\"cmd\":\(command)}\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    func openPlayerApp() {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func runAdapter(_ paths: AdapterPaths, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script.path, paths.framework.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    #if DEBUG
    /// Feed bridge-format JSON as if it came from the stream.
    func debugConsume(_ data: Data) { consume(data) }
    #endif
}

// MARK: - Where the media helpers live

struct BridgeLaunch {
    let script: URL
    let library: URL
}

/// The bridge and the command adapter: inside the .app bundle, or in vendor/ during development.
struct AdapterPaths {
    let script: URL
    let framework: URL

    static func locate() -> AdapterPaths? {
        let fm = FileManager.default
        var candidates: [AdapterPaths] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(AdapterPaths(
                script: resources.appendingPathComponent("mediaremote-adapter.pl"),
                framework: Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework")))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let vendor = dir.appendingPathComponent("vendor/mediaremote-adapter")
            candidates.append(AdapterPaths(
                script: vendor.appendingPathComponent("bin/mediaremote-adapter.pl"),
                framework: vendor.appendingPathComponent("build/MediaRemoteAdapter.framework")))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fm.fileExists(atPath: $0.script.path) && fm.fileExists(atPath: $0.framework.path) }
    }
}

extension NowPlayingService {
    static func adapterPaths() -> AdapterPaths? { AdapterPaths.locate() }

    static func launchConfiguration() -> BridgeLaunch? {
        let fm = FileManager.default
        var candidates: [BridgeLaunch] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(BridgeLaunch(
                script: resources.appendingPathComponent("bridge.pl"),
                library: Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libMediaRemoteBridge.dylib")))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let vendor = dir.appendingPathComponent("vendor/MediaRemoteBridge")
            candidates.append(BridgeLaunch(
                script: vendor.appendingPathComponent("bridge.pl"),
                library: dir.appendingPathComponent("build/libMediaRemoteBridge.dylib")))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fm.fileExists(atPath: $0.script.path) && fm.fileExists(atPath: $0.library.path) }
    }
}

extension NSImage {
    /// Average colour of the image, pushed toward something bright enough to read on black.
    var vibrantAverageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s < 0.15 ? s : max(s, 0.55), brightness: max(b, 0.85), alpha: 1)
    }
}
