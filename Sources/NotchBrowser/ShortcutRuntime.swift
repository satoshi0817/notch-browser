import AppKit
import Carbon
import Combine

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
    var carbon: Int {
        (contains(.control) ? controlKey : 0) | (contains(.option) ? optionKey : 0) |
        (contains(.shift) ? shiftKey : 0) | (contains(.command) ? cmdKey : 0)
    }
    var appKit: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }
}

extension ShortcutBinding {
    func apply(to item: NSMenuItem) {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        guard strokes.count == 1, let stroke = strokes.first else { return }
        let special: [Int:String] = [
            36:"\r", 48:"\t", 49:" ", 51:"\u{7f}", 53:"\u{1b}", 76:"\u{3}", 117:"\u{f728}",
            123:"\u{f702}", 124:"\u{f703}", 125:"\u{f701}", 126:"\u{f700}",
            115:"\u{f729}", 119:"\u{f72b}", 116:"\u{f72c}", 121:"\u{f72d}", 114:"\u{f746}"
        ]
        let name = ShortcutStroke.names[stroke.keyCode] ?? ""
        if let key = special[stroke.keyCode] { item.keyEquivalent = key }
        else if name.hasPrefix("F"), let number = Int(name.dropFirst()), let scalar = UnicodeScalar(0xf703 + number) {
            item.keyEquivalent = String(scalar)
        }
        else if name.count == 1 {
            let key = name == "−" ? "-" : name
            item.keyEquivalent = stroke.modifiers.contains(.shift) ? key.uppercased() : key.lowercased()
        }
        else { return } // Never claim an incorrect equivalent for a sequence or special key.
        item.keyEquivalentModifierMask = stroke.modifiers.appKit
    }
}

final class CarbonShortcutRegistrar: ShortcutRegistrar {
    private var next = 0
    private var registrations: [Int:HotKey] = [:]
    func register(_ stroke: ShortcutStroke, action: @escaping () -> Void) -> Int? {
        let hotKey = HotKey(keyCode: stroke.keyCode, modifiers: stroke.modifiers.carbon, action: action)
        guard hotKey.registered else { hotKey.invalidate(); return nil }
        next += 1; registrations[next] = hotKey; return next
    }
    func unregister(_ token: Int) { registrations.removeValue(forKey: token)?.invalidate() }
}

/// flagsChanged tracks modifiers. Key/mouse/scroll events only interrupt history; key contents are never read.
final class ModifierShortcutTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var machine = ModifierDoublePressMachine()
    private let action: (ShortcutModifiers) -> Void
    private var active = true
    func deactivate() { active = false; machine.interrupt() }
    func interrupt() { machine.interrupt() }
    private func reset() {
        machine.cancel(held: ShortcutModifiers(NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))))
    }
    init?(action: @escaping (ShortcutModifiers) -> Void) {
        self.action = action
        guard CGPreflightListenEventAccess() else { return nil }
        let eventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: eventTypes
                .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) },
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ModifierShortcutTap>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.reset()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .flagsChanged {
                    let flags = ShortcutModifiers(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
                    if let modifier = owner.machine.update(flags, at: ProcessInfo.processInfo.systemUptime, secureInput: IsSecureEventInputEnabled()) {
                        if owner.active { owner.action(modifier) }
                    }
                } else {
                    owner.machine.interrupt()
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return nil }
        reset()
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

final class ShortcutController: ObservableObject {
    static let shared = ShortcutController()
    @Published private(set) var errors: [GlobalShortcutAction:String] = [:]
    @Published private(set) var needsPermission = false
    var onAction: ((GlobalShortcutAction) -> Void)?
    private let registrar: ShortcutRegistrar
    private let store: SettingsStore
    private let loadPreferences: () -> ShortcutPreferences
    private var pendingRebuild: DispatchWorkItem?
    private let permissionAvailable: () -> Bool
    private var actionGeneration = 0
    private lazy var keys = ShortcutKeyMachine(registrar: registrar, now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, callback in
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            callback()
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }, action: { [weak self] action in self?.fire(action) }, registrationFailed: { [weak self] action in
        self?.errors[action] = "このキーは登録できませんでした"
    }, keyPressed: { [weak self] in self?.tap?.interrupt() })
    private var activityMonitor: Any?
    private var tap: ModifierShortcutTap?
    private var subscription: AnyCancellable?
    private var permissionTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var preferences = ShortcutPreferences()
    private var suspended = false
    private var running = false
    init(registrar: ShortcutRegistrar = CarbonShortcutRegistrar(),
         store: SettingsStore = .shared,
         loadPreferences: (() -> ShortcutPreferences)? = nil,
         permissionAvailable: @escaping () -> Bool = { CGPreflightListenEventAccess() }) {
        self.registrar = registrar
        self.store = store
        self.loadPreferences = loadPreferences ?? { store.data.shortcuts }
        self.permissionAvailable = permissionAvailable
    }
    func start() {
        shutdown()
        running = true
        preferences = loadPreferences()
        rebuild()
        subscription = store.$data.map(\.shortcuts).removeDuplicates().dropFirst().sink { [weak self] value in
            self?.preferences = value; self?.scheduleRebuild()
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermission()
        }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown {
                self?.localKeyDown(ShortcutStroke(keyCode: Int(event.keyCode), modifiers: ShortcutModifiers(event.modifierFlags)))
            } else { self?.cancelPending() }
            return event
        }
    }
    private var preferencesHasDouble: Bool {
        GlobalShortcutAction.allCases.contains { if case .doubleModifier = preferences[$0] { return true }; return false }
    }
    private func refreshPermission() {
        guard running else { return }
        let needed = preferencesHasDouble && !permissionAvailable()
        if needed != needsPermission { refreshModifierTap() }
        updatePermissionPolling()
    }
    private func updatePermissionPolling() {
        guard ShortcutPermissionPolling.shouldRun(running: running, recording: suspended,
                                                  hasDoublePress: preferencesHasDouble, needsPermission: needsPermission) else {
            permissionTimer?.invalidate(); permissionTimer = nil
            return
        }
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermission() }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func suspend(_ value: Bool) {
        suspended = value
        if value { clear() }
        scheduleRebuild()
    }
    // Publish settings synchronously; defer permission IPC and tap lifecycle, not UI state.
    private func scheduleRebuild() {
        if running && !suspended { keys.start(preferences) }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshModifierTap()
            self?.updatePermissionPolling()
        }
        pendingRebuild = work
        DispatchQueue.main.async(execute: work)
    }
    func shutdown() {
        running = false
        pendingRebuild?.cancel(); pendingRebuild = nil
        subscription = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }; activeObserver = nil
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }; activityMonitor = nil
        clear()
    }
    func cancelPending() { keys.cancelPending() }
    func localKeyDown(_ stroke: ShortcutStroke) { tap?.interrupt(); keys.localKeyDown(stroke) }
    private func clear() {
        actionGeneration += 1
        keys.stop()
        if let oldTap = tap {
            oldTap.deactivate()
            tap = nil
            DispatchQueue.main.async { withExtendedLifetime(oldTap) {} }
        }
    }
    private func rebuild() {
        defer { updatePermissionPolling() }
        clear(); errors = [:]
        if running && !suspended { keys.start(preferences) }
        refreshModifierTap()
    }
    private func refreshModifierTap() {
        tap = nil
        for action in GlobalShortcutAction.allCases {
            if case .doubleModifier = preferences[action] { errors[action] = nil }
        }
        needsPermission = preferencesHasDouble && !permissionAvailable()
        guard running && !suspended else { return }
        if preferencesHasDouble && !needsPermission {
            tap = ModifierShortcutTap { [weak self] modifier in
                guard let self else { return }
                for action in GlobalShortcutAction.allCases where self.preferences[action] == .doubleModifier(modifier) { self.fire(action) }
            }
            if tap == nil {
                for action in GlobalShortcutAction.allCases {
                    if case .doubleModifier = preferences[action] { errors[action] = "このキーは登録できませんでした" }
                }
            }
        }
    }
    private func fire(_ action: GlobalShortcutAction) {
        cancelPending()
        let generation = actionGeneration
        // UI changes can run after Carbon dispatch; prefix/temporary registration cannot.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, !self.suspended, self.actionGeneration == generation else { return }
            self.onAction?(action)
        }
    }
    /// Probe after stopping the previous registrations; failure leaves saved preferences intact.
    func set(_ binding: ShortcutBinding, for action: GlobalShortcutAction) -> String? {
        precondition(Thread.isMainThread)
        var candidate = store.data.shortcuts
        if let error = candidate.error(for: binding, action: action) { return error }
        clear()
        var probes: [Int] = []
        for stroke in Set(binding.strokes) {
            guard let token = registrar.register(stroke, action: {}) else {
                probes.forEach(registrar.unregister); rebuild()
                return "このキーは登録できませんでした"
            }
            probes.append(token)
        }
        probes.forEach(registrar.unregister)
        candidate[action] = binding
        errors = [:]
        store.data.shortcuts = candidate
        preferences = candidate; scheduleRebuild()
        return nil
    }
    func resetAll() {
        precondition(Thread.isMainThread)
        clear()
        let candidate = ShortcutPreferences()
        var probes: [Int] = []
        for action in GlobalShortcutAction.allCases {
            guard let first = candidate[action].strokes.first,
                  let token = registrar.register(first, action: {}) else {
                probes.forEach(registrar.unregister); rebuild()
                errors[action] = "このキーは登録できませんでした"; return
            }
            probes.append(token)
        }
        probes.forEach(registrar.unregister)
        errors = [:]
        store.data.shortcuts = candidate
        preferences = candidate; scheduleRebuild()
    }
    deinit {
        permissionTimer?.invalidate()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        clear()
    }
}
