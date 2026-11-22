import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.ps

/// Tracks the current audio output device and lets the user pick another one.
///
/// The notch shows what you are *listening on* — AirPods, the built-in speakers, a display — which
/// is a system-level property, so it comes from CoreAudio rather than from the player.
@Observable @MainActor
final class AudioOutputService {
    struct Output: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let symbol: String
    }

    static let shared = AudioOutputService()

    private(set) var current: Output?

    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    private init() {
        current = Self.output(for: Self.defaultDeviceID())
        listenForChanges()
    }

    /// Every device that can play sound, in the order the system reports them.
    func outputs() -> [Output] {
        Self.allDeviceIDs()
            .filter { Self.hasOutputChannels($0) }
            .map { Self.output(for: $0) }
            .filter { !$0.name.isEmpty }
    }

    func setDefault(_ id: AudioDeviceID) {
        var device = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        refresh()
    }

    func refresh() {
        current = Self.output(for: Self.defaultDeviceID())
    }

    // MARK: - CoreAudio plumbing

    private func listenForChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                            DispatchQueue.main, block)
    }

    private static func defaultDeviceID() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func hasOutputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func output(for device: AudioDeviceID) -> Output {
        Output(id: device, name: name(of: device), symbol: symbol(for: name(of: device), device: device))
    }

    /// Bluetooth and USB names are all we get, so match the words that reliably mean "wearable".
    private static func looksLikeHeadphones(_ name: String) -> Bool {
        ["headphone", "earphone", "earbud", "headset", "beats", "quietcomfort", "wh-", "wf-",
         "buds", "bose qc", "耳机", "降噪"].contains { name.contains($0) }
    }

    /// …and the ones that mean a box with a woofer in it.
    private static func looksLikeSpeaker(_ name: String) -> Bool {
        ["speaker", "soundbar", "subwoofer", "homepod", "sonos", "jbl", "bose", "marshall",
         "harman", "soundcore", "anker", "boom", "charge", "flip", "pill", "ue ",
         "音箱", "音响", "音箱"].contains { name.contains($0) }
    }

    /// The Mac's own model identifier. Apple Silicon reports numbers ("Mac16,1") rather than
    /// family names, so the family is inferred from hardware instead of from the string.
    private static let modelIdentifier: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return "" }
        return String(cString: model)
    }()

    /// A laptop has a battery; that is the one distinction Apple's identifiers no longer carry.
    private static let hasBattery: Bool = {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else { return false }
        return true
    }()

    /// An all-in-one has a built-in display; a headless desktop does not.
    private static let hasBuiltInDisplay: Bool = CGDisplayIsBuiltin(CGMainDisplayID()) != 0

    /// Apple Silicon desktops by model identifier. Anything unlisted falls through to a mini.
    private static let studioModels: Set<String> = ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac16,9"]
    private static let proModels: Set<String> = ["Mac14,8"]

    /// SF Symbol for this Mac, chosen by family; each candidate is checked because the older
    /// symbols do not exist on every macOS version.
    static let builtInSymbol: String = {
        let candidates: [String]
        if hasBattery {
            candidates = ["laptopcomputer"]
        } else if hasBuiltInDisplay || modelIdentifier.hasPrefix("iMac") {
            candidates = ["desktopcomputer"]
        } else if proModels.contains(modelIdentifier) {
            candidates = ["macpro", "desktopcomputer"]
        } else if studioModels.contains(modelIdentifier) {
            candidates = ["macstudio", "macmini", "desktopcomputer"]
        } else {
            candidates = ["macmini", "desktopcomputer"]
        }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            ?? "desktopcomputer"
    }()

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "" }
        return name as String
    }

    private static func transport(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }

    /// SF Symbol for the device.
    ///
    /// The name heuristics only apply to wireless/wired accessories: the built-in device is called
    /// "MacBook Pro Speakers", which would otherwise match "speaker" and hide the fact that it is
    /// the machine itself.
    private static func symbol(for name: String, device: AudioDeviceID) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }

        switch transport(of: device) {
        case kAudioDeviceTransportTypeBuiltIn:
            if lower.contains("headphone") || lower.contains("耳机") { return "headphones" }
            return builtInSymbol
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if looksLikeHeadphones(lower) { return "headphones" }
            if looksLikeSpeaker(lower) { return "hifispeaker.fill" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            if looksLikeHeadphones(lower) { return "headphones" }
            if looksLikeSpeaker(lower) { return "hifispeaker.fill" }
            return transport(of: device) == kAudioDeviceTransportTypeUSB ? "hifispeaker.fill" : "speaker.wave.2.fill"
        }
    }

    /// Bluetooth and USB names are all we get, so match the words that reliably mean "wearable".
}
