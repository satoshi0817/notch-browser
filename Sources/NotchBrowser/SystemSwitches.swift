import AppKit
import CoreAudio
import CoreWLAN
import Combine

struct SwitchAudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// Read real system state; never persist a pretend on/off state for a system control.
final class SystemSwitchStore: ObservableObject {
    @Published private(set) var dark = false
    @Published private(set) var desktopHidden = false
    @Published private(set) var hiddenFiles = false
    @Published private(set) var dockHidden = false
    @Published private(set) var wifi: Bool?
    @Published private(set) var outputs: [SwitchAudioDevice] = []
    @Published private(set) var outputID = AudioDeviceID(0)
    @Published private(set) var microphoneMuted = false
    @Published private(set) var microphoneAvailable = false
    @Published private(set) var busy = false
    @Published var message: String?
    private var timer: Timer?
    private var inputID = AudioDeviceID(0)

    deinit { timer?.invalidate() }
    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    static func preference(_ key: String, domain: String) -> Any? {
        let application = domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
        CFPreferencesAppSynchronize(application)
        return CFPreferencesCopyAppValue(key as CFString, application)
    }
    func refresh() {
        dark = Self.preference("AppleInterfaceStyle", domain: "NSGlobalDomain") as? String == "Dark"
        desktopHidden = !(Self.preference("CreateDesktop", domain: "com.apple.finder") as? Bool ?? true)
        hiddenFiles = Self.preference("AppleShowAllFiles", domain: "com.apple.finder") as? Bool ?? false
        dockHidden = Self.preference("autohide", domain: "com.apple.dock") as? Bool ?? false
        wifi = CWWiFiClient.shared().interface()?.powerOn()
        refreshDevices()
    }
    private func script(_ source: String) {
        guard !busy else { return }
        busy = true; message = nil
        // Apple events run serially off the UI thread and have an explicit timeout.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "with timeout of 15 seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
            let failed = error != nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.message = failed ? "変更できませんでした。システム設定 › プライバシーとセキュリティ › オートメーションを確認してください。" : nil
                self.refresh()
            }
        }
    }
    func setDark(_ value: Bool) {
        script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
    }
    func setDockHidden(_ value: Bool) {
        script("tell application \"System Events\" to tell dock preferences to set autohide to \(value)")
    }
    func setFinderPreference(_ key: String, value: Bool) {
        guard ["CreateDesktop", "AppleShowAllFiles"].contains(key), !busy else { return }
        busy = true; message = nil
        Self.run("/usr/bin/defaults", ["write", "com.apple.finder", key, "-bool", value ? "true" : "false"]) { [weak self] success in
            guard let self else { return }
            guard success else { self.busy = false; self.message = "Finderの設定を変更できませんでした。"; return }
            Self.run("/usr/bin/killall", ["Finder"]) { [weak self] _ in
                self?.busy = false; self?.refresh()
            }
        }
    }
    func setWiFi(_ value: Bool) {
        guard !busy else { return }
        busy = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var success = false
            do {
                if let interface = CWWiFiClient.shared().interface() { try interface.setPower(value); success = true }
            } catch { }
            DispatchQueue.main.async { [weak self] in
                self?.busy = false; self?.message = success ? nil : "Wi-Fiを変更できませんでした。システム設定で確認してください。"
                self?.refresh()
            }
        }
    }
    static func run(_ path: String, _ arguments: [String], completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); let success = process.terminationStatus == 0
                DispatchQueue.main.async { completion(success) }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }
    func sleepDisplay() {
        Self.run("/usr/bin/pmset", ["displaysleepnow"]) { [weak self] success in
            if !success { self?.message = "画面を消灯できませんでした。" }
        }
    }
    func startScreenSaver() {
        let candidates = ["/System/Library/CoreServices/ScreenSaverEngine.app", "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine"]
        guard let path = candidates.first(where: FileManager.default.fileExists(atPath:)) else { message = "スクリーンセーバーが見つかりません。"; return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { [weak self] _, error in
            if error != nil { DispatchQueue.main.async { self?.message = "スクリーンセーバーを開始できませんでした。" } }
        }
    }
    func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        if !NSWorkspace.shared.open(url) { message = "システム設定を開けませんでした。" }
    }
    private func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = property(selector), id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }
    func refreshDevices() {
        outputID = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        inputID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        var address = property(kAudioHardwarePropertyDevices), size: UInt32 = 0
        var devices: [AudioDeviceID] = []
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr {
            devices = Array(repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard !devices.isEmpty else { outputs = []; microphoneAvailable = false; return }
            let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
            if status != noErr { devices = [] }
        }
        outputs = devices.compactMap { id in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput), streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = property(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
            guard let name else { return nil }
            return SwitchAudioDevice(id: id, name: name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var mute = property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false, value: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        microphoneAvailable = inputID != 0 && AudioObjectHasProperty(inputID, &mute)
            && AudioObjectIsPropertySettable(inputID, &mute, &settable) == noErr && settable.boolValue
            && AudioObjectGetPropertyData(inputID, &mute, 0, nil, &size, &value) == noErr
        microphoneMuted = microphoneAvailable && value != 0
    }
    func selectOutput(_ id: AudioDeviceID) {
        refreshDevices()
        guard outputs.contains(where: { $0.id == id }) else { message = "出力機器が切断されています。"; return }
        var address = property(kAudioHardwarePropertyDefaultOutputDevice), value = id
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        message = result == noErr ? nil : "出力先を変更できませんでした。"
        refreshDevices()
    }
    func setMicrophoneMuted(_ muted: Bool) {
        refreshDevices()
        guard microphoneAvailable else { return }
        var address = property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput), value: UInt32 = muted ? 1 : 0
        let result = AudioObjectSetPropertyData(inputID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        message = result == noErr ? nil : "マイクを変更できませんでした。"
        refreshDevices()
    }
}
