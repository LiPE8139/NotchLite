import AppKit
import Foundation

/// Checks GitHub Releases for a newer build, and can install it in place.
///
/// There is no Sparkle here: the app is not notarised and the release assets are plain DMG/ZIP, so
/// an update is "download the ZIP, unpack it, swap the bundle, relaunch". That is a destructive
/// operation, so it only ever runs from `/Applications` and always through a helper script that
/// waits for this process to exit first.
@Observable @MainActor
final class UpdateService {
    struct Release {
        let version: String
        let zipURL: URL
        let pageURL: URL
        let notes: String
    }

    enum UpdateError: LocalizedError {
        case noRelease
        case notInstalled
        case badPayload

        var errorDescription: String? {
            switch self {
            case .noRelease: return "找不到可用的发布版本"
            case .notInstalled: return "请先把 App 放进「应用程序」文件夹再更新"
            case .badPayload: return "下载的更新包无法识别"
            }
        }
    }

    static let repo = "LiPE8139/NotchLite"
    static let autoUpdateKey = "autoUpdateEnabled"

    /// Set from the settings menu; remembered across launches.
    var autoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoUpdateKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoUpdateKey) }
    }

    private(set) var isBusy = false
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Looking for a release

    func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError.noRelease }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: currentVersion) else { return nil }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let zipURL = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError.noRelease
        }
        let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(Self.repo)/releases")!
        return Release(version: version, zipURL: zipURL, pageURL: pageURL,
                       notes: json["body"] as? String ?? "")
    }

    /// Dotted numeric comparison: 1.10 is newer than 1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Checking

    /// Manual check: always tells the user something, even when up to date.
    func checkManually() {
        guard !isBusy else { return }
        Task { @MainActor in
            isBusy = true
            defer { isBusy = false }
            do {
                guard let release = try await latestRelease() else {
                    alert(title: "已是最新版本",
                          message: "当前版本 \(currentVersion) 已经是最新的了。")
                    return
                }
                offer(release)
            } catch {
                alert(title: "检查更新失败", message: error.localizedDescription)
            }
        }
    }

    /// Silent check on launch and on a slow timer.
    func checkInBackground() {
        guard !isBusy else { return }
        Task { @MainActor in
            isBusy = true
            defer { isBusy = false }
            // Swift flattens `try?` over an optional result, so this binds a non-optional Release.
            guard let release = try? await latestRelease() else { return }
            if autoUpdateEnabled {
                // Automatic: install and relaunch, no questions. The delay gives the user a moment
                // to see it happen rather than having the app vanish mid-click.
                try? await Task.sleep(for: .seconds(3))
                alert(title: "正在更新到 \(release.version)",
                      message: "NotchLite 会下载新版本、替换自身并重新启动。")
                await install(release)
            } else {
                offer(release)
            }
        }
    }

    /// Poll every six hours; the first check happens shortly after launch.
    func startBackgroundChecks() {
        guard timer == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            checkInBackground()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInBackground() }
        }
    }

    // MARK: - Offering and installing

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "有新版本 \(release.version)"
        alert.informativeText = "当前版本 \(currentVersion)。是否现在下载并安装？"
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "查看发布说明")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in await install(release) }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    func install(_ release: Release) async {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            alert(title: "无法自动更新", message: UpdateError.notInstalled.localizedDescription)
            return
        }
        do {
            let work = try await download(release)
            try swap(in: work)
        } catch {
            alert(title: "更新失败", message: error.localizedDescription)
        }
    }

    private func download(_ release: Release) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: release.zipURL)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchLiteUpdate-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", tmp.path, work.path])
        return work
    }

    /// Hands the swap to a helper: this process cannot replace its own bundle while running.
    private func swap(in work: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.badPayload }

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("notchlite-update.sh")
        let body = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf /Applications/NotchLite.app
        /usr/bin/ditto "\(app.path)" /Applications/NotchLite.app
        /usr/bin/xattr -dr com.apple.quarantine /Applications/NotchLite.app 2>/dev/null
        /usr/bin/open -a /Applications/NotchLite.app
        rm -rf "\(work.path)" "$0"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try run("/bin/bash", [script.path])
        NSApp.terminate(nil)
    }

    private func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
