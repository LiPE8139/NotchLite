import AppKit
import Foundation
import SwiftUI

/// The session macOS is currently playing, as reported by the MediaRemote bridge.
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
    /// When the bridge reported this snapshot; elapsed is extrapolated from here.
    var reportedAt: Date

    var id: String { bundleID }

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying, rate > 0 else { return max(0, min(elapsed, duration > 0 ? duration : elapsed)) }
        let projected = elapsed + date.timeIntervalSince(reportedAt) * rate
        return duration > 0 ? min(max(projected, 0), duration) : max(projected, 0)
    }
}

/// Reads the active Now Playing session and drives it.
///
/// Since macOS 15.4 MediaRemote refuses non-Apple callers, so the bridge is a dylib loaded by
/// `/usr/bin/perl` — the same trick the mediaremote-adapter uses for commands.
@Observable @MainActor
final class NowPlayingService {
    private(set) var source: MediaSource?
    private(set) var isAvailable = true
    private(set) var showsActivity = false

    @ObservationIgnored var onTrackChange: (() -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var commandPipe: Pipe?
    @ObservationIgnored private var lineBuffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var hideActivityTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackKey = ""
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var accents: [String: Color] = [:]
    @ObservationIgnored private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored private var artworkAccent: [String: Color] = [:]
    @ObservationIgnored private var artworkVersion: [String: Int] = [:]
    @ObservationIgnored private var artworkKey: [String: String] = [:]
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    // MARK: - What the views read

    var title: String {
        guard let source else { return "" }
        return source.title.isEmpty ? source.displayName : source.title
    }
    var artist: String { source?.artist ?? "" }
    var album: String { source?.album ?? "" }
    var duration: TimeInterval { source?.duration ?? 0 }
    var isPlaying: Bool { source?.isPlaying ?? false }
    var hasMedia: Bool { source != nil }
    var bundleID: String? { source?.bundleID }
    var displayName: String { source?.displayName ?? "" }

    /// The active session is by definition the one macOS accepts commands for.
    var canControl: Bool { source != nil }
    var canSeek: Bool { source != nil }

    var artwork: NSImage? {
        guard let source else { return nil }
        return artworkCache[source.bundleID] ?? icon(for: source.bundleID)
    }

    var playerIcon: NSImage? { source.map { icon(for: $0.bundleID) } }

    var accent: Color {
        guard let bundle = source?.bundleID else { return .white }
        return artworkAccent[bundle] ?? accents[bundle] ?? .white
    }

    func elapsed(at date: Date) -> TimeInterval { source?.elapsed(at: date) ?? 0 }

    /// Changes whenever the track does; drives the text cross-fade.
    var trackIdentity: String {
        guard let source else { return "" }
        return "\(source.bundleID)|\(source.title)|\(source.artist)"
    }

    /// Bumped whenever a new cover is stored, so views can animate on the image itself.
    var artworkIdentity: String {
        guard let bundle = source?.bundleID else { return "" }
        return "\(bundle)#\(artworkVersion[bundle] ?? 0)"
    }

    /// Player icon, also used where the artwork is missing.
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

        // Only the session macOS is driving is shown: it is the one commands can reach.
        guard var item = raw.first(where: { $0["active"] as? Bool == true }) ?? raw.first,
              let bundle = item["bundle"] as? String, !bundle.isEmpty else {
            if source != nil { source = nil; showsActivity = false }
            return
        }
        item.removeValue(forKey: "active")

        var parsed = MediaSource(
            bundleID: bundle,
            displayName: item["name"] as? String ?? bundle,
            pid: Int32(item["pid"] as? Int ?? 0),
            title: item["title"] as? String ?? "",
            artist: item["artist"] as? String ?? "",
            album: item["album"] as? String ?? "",
            duration: item["duration"] as? Double ?? 0,
            elapsed: item["elapsed"] as? Double ?? 0,
            rate: item["rate"] as? Double ?? 0,
            isPlaying: item["playing"] as? Bool ?? false,
            reportedAt: now)

        // Keep extrapolating from the previous anchor while the report merely tracks playback;
        // re-anchor only on a real jump (a seek) or a new track.
        if let old = source, old.bundleID == bundle, old.title == parsed.title, old.duration == parsed.duration {
            let predicted = old.elapsed(at: now)
            if abs(parsed.elapsed - predicted) < 1.5 {
                parsed.elapsed = old.elapsed
                parsed.reportedAt = old.reportedAt
            }
        }

        let previousKey = lastTrackKey
        source = parsed
        lastTrackKey = trackKey(of: parsed)
        updateActivity()
        refreshArtwork(for: parsed)

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

    // MARK: - Artwork

    /// Players publish the cover a moment after the metadata, so the first read often comes back
    /// empty. Retry briefly, then keep whatever the player last offered.
    private func refreshArtwork(for source: MediaSource) {
        let key = "\(source.title)|\(source.artist)"
        guard artworkKey[source.bundleID] != key, artworkTask == nil else { return }
        artworkTask = Task { [weak self] in
            for attempt in 1...4 {
                if let loaded = await Self.loadArtwork() {
                    self?.store(artwork: loaded.image, for: loaded.bundle)
                    self?.artworkKey[source.bundleID] = key
                    break
                }
                if attempt < 4 { try? await Task.sleep(for: .milliseconds(450)) }
            }
            guard let self else { return }
            if self.artworkKey[source.bundleID] != key { self.artworkKey[source.bundleID] = key }
            self.artworkTask = nil
        }
    }

    private func store(artwork image: NSImage, for bundle: String) {
        var covers = artworkCache
        covers[bundle] = image
        artworkCache = covers
        artworkVersion[bundle, default: 0] += 1
        if let tint = image.vibrantAverageColor {
            var tints = artworkAccent
            tints[bundle] = Color(nsColor: tint)
            artworkAccent = tints
        }
    }

    /// One-shot read of the active session's artwork through the single-session adapter.
    private static func loadArtwork() async -> (bundle: String, image: NSImage)? {
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
                      let image = thumbnail(from: raw, maxPixelSize: 512)
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

    // MARK: - Transport

    func togglePlayPause() {
        send(2)
        updateActivity()
    }

    func next() { send(4) }
    func previous() { send(5) }

    func seek(to seconds: TimeInterval) {
        guard let adapter = Self.adapterPaths() else { return }
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
        for _ in 0..<5 {
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
