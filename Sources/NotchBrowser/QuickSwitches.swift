import AppKit
import SwiftUI
import CoreAudio
import IOKit.pwr_mgt

final class QuickSwitchStore: ObservableObject {
    @Published private(set) var awakeUntil: Date?
    @Published private(set) var keepsDisplayAwake = false
    var isAwake: Bool { assertion != 0 }
    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var volumeAvailable = false
    @Published private(set) var muteAvailable = false
    @Published private(set) var shortcuts: [String] = []
    @Published private(set) var running = false
    @Published var message: String?
    private var assertion = IOPMAssertionID(0)
    private var expiry: Timer?
    private var audioTimer: Timer?
    private var device = AudioDeviceID(0)

    deinit {
        expiry?.invalidate(); audioTimer?.invalidate()
        if assertion != 0 { IOPMAssertionRelease(assertion) }
    }

    func keepAwake(minutes: Int, display: Bool = false) {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        expiry?.invalidate(); expiry = nil; awakeUntil = nil
        keepsDisplayAwake = false
        guard minutes != 0 else { message = nil; return }
        guard minutes == -1 || (1...1440).contains(minutes) else { message = "抑止時間を選び直してください。"; return }
        let result = IOPMAssertionCreateWithName((display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep) as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "NotchBrowser 作業中" as CFString, &assertion)
        guard result == kIOReturnSuccess else { assertion = 0; message = "スリープ抑止を開始できませんでした。"; return }
        keepsDisplayAwake = display
        awakeUntil = minutes < 0 ? .distantFuture : Date().addingTimeInterval(Double(minutes * 60))
        if minutes > 0 { expiry = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in self?.keepAwake(minutes: 0) } }
        message = nil
    }

    func startObserving() {
        refreshAudio()
        guard audioTimer == nil else { return }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshAudio() }
    }
    func stopObserving() { audioTimer?.invalidate(); audioTimer = nil }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private func writable(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
    func refreshAudio() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            volumeAvailable = false; muteAvailable = false; return
        }
        volumeAvailable = writable(kAudioDevicePropertyVolumeScalar)
        muteAvailable = writable(kAudioDevicePropertyMute)
        var scalar: Float32 = 0
        address = self.address(kAudioDevicePropertyVolumeScalar); size = UInt32(MemoryLayout<Float32>.size)
        if volumeAvailable, AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr { volume = Double(scalar) }
        else { volumeAvailable = false }
        var mute: UInt32 = 0
        address = self.address(kAudioDevicePropertyMute); size = UInt32(MemoryLayout<UInt32>.size)
        if muteAvailable, AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr { muted = mute != 0 }
        else { muteAvailable = false }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        refreshAudio()
        guard volumeAvailable else { return }
        var address = address(kAudioDevicePropertyVolumeScalar)
        var value = Float32(min(1, max(0, value)))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        message = status == noErr ? nil : "音量を変更できませんでした。"
        refreshAudio()
    }
    func setMuted(_ value: Bool) {
        refreshAudio()
        guard muteAvailable else { return }
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = value ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        message = status == noErr ? nil : "ミュートを変更できませんでした。"
        refreshAudio()
    }

    func loadShortcuts() {
        executeShortcuts(["list"]) { [weak self] success, output in
            if success { self?.shortcuts = output.split(separator: "\n").map(String.init).sorted() }
            else { self?.message = "ショートカットを読み込めませんでした。" }
        }
    }
    func runShortcut(_ name: String) {
        guard !running, shortcuts.contains(name) else { return }
        running = true; message = nil
        executeShortcuts(["run", name]) { [weak self] success, _ in
            self?.running = false
            self?.message = success ? "ショートカットを実行しました。" : "実行できませんでした。ショートカットアプリで権限や設定を確認してください。"
        }
    }
    private func executeShortcuts(_ arguments: [String], completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                DispatchQueue.main.async { completion(process.terminationStatus == 0, String(data: output, encoding: .utf8) ?? "") }
            } catch { DispatchQueue.main.async { completion(false, "") } }
        }
    }
}
