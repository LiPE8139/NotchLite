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
    @ObservationIgnored private var lineBuffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var hideActivityTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackKey = ""
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var accents: [String: Color] = [:]

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

    /// Transport only works while the shown session is the one the system is driving.
    var canControl: Bool { selected?.isActive ?? false }

    /// Album art is not available for secondary sessions yet, so fall back to the player's icon.
    var artwork: NSImage? { selected.map { icon(for: $0.bundleID) } }
    var playerIcon: NSImage? { selected.map { icon(for: $0.bundleID) } }
    var accent: Color {
        guard let bundle = selected?.bundleID else { return .white }
        return accents[bundle] ?? .white
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
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
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

        if lastTrackKey != previousKey, !lastTrackKey.isEmpty, isPlaying {
            onTrackChange?()
        }
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

    /// The bridge reports which session is active; commands go to that one. Passing through the
    /// old adapter keeps a single, already-proven command path until per-client sending is wired.
    func togglePlayPause() {
        guard canControl else { return }
        send(2)
        updateActivity()
    }

    func next() {
        guard canControl else { return }
        send(4)
    }

    func previous() {
        guard canControl else { return }
        send(5)
    }

    func seek(to seconds: TimeInterval) {
        guard canControl, let adapter = Self.adapterPaths() else { return }
        runAdapter(adapter, ["seek", String(Int(seconds * 1_000_000))])
    }

    func openPlayerApp() {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: Int) {
        guard let adapter = Self.adapterPaths() else { return }
        runAdapter(adapter, ["send", String(command)])
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
