import Foundation

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let control = Self(rawValue: 1)
    static let option = Self(rawValue: 2)
    static let shift = Self(rawValue: 4)
    static let command = Self(rawValue: 8)
    var display: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
    var isSingle: Bool { rawValue.nonzeroBitCount == 1 }
}

struct ShortcutStroke: Codable, Hashable {
    var keyCode: Int
    var modifiers: ShortcutModifiers
    var display: String { modifiers.display + (Self.names[keyCode] ?? "キー\(keyCode)") }
    static let names: [Int: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
        12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4",
        22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8", 29:"0", 30:"]", 31:"O",
        32:"U", 33:"[", 34:"I", 35:"P", 36:"↩", 37:"L", 38:"J", 39:"'", 40:"K", 41:";",
        42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"⇥", 49:"Space", 50:"`", 51:"⌫", 53:"⎋",
        64:"F17", 65:"テンキー .", 67:"テンキー *", 69:"テンキー +", 71:"Clear", 75:"テンキー /",
        76:"⌤", 78:"テンキー −", 79:"F18", 80:"F19", 81:"テンキー =", 82:"テンキー 0",
        83:"テンキー 1", 84:"テンキー 2", 85:"テンキー 3", 86:"テンキー 4", 87:"テンキー 5",
        88:"テンキー 6", 89:"テンキー 7", 90:"F20", 91:"テンキー 8", 92:"テンキー 9",
        93:"¥", 94:"_", 95:"テンキー ,", 96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9",
        102:"英数", 103:"F11", 104:"かな", 105:"F13", 106:"F16", 107:"F14", 109:"F10", 111:"F12",
        113:"F15", 114:"Help", 115:"↖", 116:"⇞", 117:"⌦", 118:"F4", 119:"↘", 120:"F2",
        121:"⇟", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑"
    ]
    var isFunction: Bool { Self.names[keyCode]?.hasPrefix("F") == true }
    var isValid: Bool { Self.names[keyCode] != nil && modifiers.rawValue & ~15 == 0 && ((!modifiers.isEmpty && modifiers != .shift) || isFunction) }
    var isReserved: Bool {
        let m = modifiers
        if keyCode == 49 && (m == .command || m == .control) { return true }
        if keyCode == 48 && (m == .command || m == [.command, .shift]) { return true }
        if keyCode == 50 && (m == .command || m == [.command, .shift]) { return true }
        if keyCode == 12 && (m == .command || m == [.control, .command]) { return true }
        if keyCode == 53 && m == [.command, .option] { return true }
        return [20,21,23].contains(keyCode) && m == [.command, .shift]
    }
}

enum GlobalShortcutAction: String, CaseIterable, Codable, Identifiable {
    case toggle, detach, detachTab
    var id: Self { self }
    var title: String {
        switch self {
        case .toggle: return "開く / 閉じる"
        case .detach: return "ブラウザ全体をウインドウにする / ノッチに戻す"
        case .detachTab: return "このタブを別ウインドウで開く"
        }
    }
    var defaultBinding: ShortcutBinding {
        if self == .detachTab { return .unassigned }
        return .keys([ShortcutStroke(keyCode: 45, modifiers: self == .toggle ? [.control,.option] : [.control,.option,.command])])
    }
}

enum ShortcutBinding: Codable, Equatable {
    case unassigned
    case keys([ShortcutStroke])
    case doubleModifier(ShortcutModifiers)
    var strokes: [ShortcutStroke] { if case .keys(let keys) = self { return keys }; return [] }
    var caps: [String] {
        switch self {
        case .unassigned: return ["未設定"]
        case .keys(let keys): return keys.map(\.display)
        case .doubleModifier(let modifier): return [modifier.display + " ×2"]
        }
    }
    var display: String { caps.joined(separator: "  ") }
    var isValid: Bool {
        switch self {
        case .unassigned: true
        case .keys(let keys): (1...2).contains(keys.count) && keys.allSatisfy(\.isValid)
        case .doubleModifier(let m): m.isSingle && m.rawValue & ~15 == 0
        }
    }
    func overlaps(_ other: Self) -> Bool {
        if self == .unassigned || other == .unassigned { return false }
        if let first = strokes.first, let second = other.strokes.first {
            // A temporary second step must not compete with another permanent prefix.
            return other.strokes.contains(first) || strokes.contains(second)
        }
        return self == other
    }
    var warning: String? {
        guard let first = strokes.first, first.modifiers.isSingle else { return nil }
        return "\(first.display) は他のアプリでは使えなくなります"
    }
}

/// Presentation only: a rejected candidate never replaces the saved binding.
struct ShortcutRowPresentation {
    let caps: [String]
    let error: String?
    let note: String?
    var hasError: Bool { error != nil }
    init(saved: ShortcutBinding, attempted: ShortcutBinding?, error: String?) {
        self.error = error
        caps = (error == nil ? saved : attempted ?? saved).caps
        note = error == nil ? saved.warning : nil
    }
}

struct ShortcutPreferences: Codable, Equatable {
    var toggle: ShortcutBinding = GlobalShortcutAction.toggle.defaultBinding
    var detach: ShortcutBinding = GlobalShortcutAction.detach.defaultBinding
    var detachTab: ShortcutBinding = .unassigned
    subscript(action: GlobalShortcutAction) -> ShortcutBinding {
        get { action == .toggle ? toggle : action == .detachTab ? detachTab : detach }
        set { if action == .toggle { toggle = newValue } else if action == .detachTab { detachTab = newValue } else { detach = newValue } }
    }
    init() {}
    /// Shared, observable-view-independent wording; nil hides keyboard guidance when unset.
    var openHint: String? { toggle == .unassigned ? nil : "\(toggle.display) で開く" }
    var openSummary: String {
        openHint.map { "ノッチにカーソルを乗せるか、\($0)" } ?? "ノッチにカーソルを乗せて開く"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toggle = (try? c.decode(ShortcutBinding.self, forKey: .toggle)).flatMap { $0.isValid ? $0 : nil } ?? GlobalShortcutAction.toggle.defaultBinding
        detach = (try? c.decode(ShortcutBinding.self, forKey: .detach)).flatMap { $0.isValid ? $0 : nil } ?? GlobalShortcutAction.detach.defaultBinding
        if error(for: toggle, action: .toggle) != nil { toggle = GlobalShortcutAction.toggle.defaultBinding }
        if error(for: detach, action: .detach) != nil { detach = GlobalShortcutAction.detach.defaultBinding }
        detachTab = (try? c.decode(ShortcutBinding.self, forKey: .detachTab)).flatMap { $0.isValid ? $0 : nil } ?? .unassigned
        if error(for: detachTab, action: .detachTab) != nil { detachTab = .unassigned }
        if toggle.overlaps(detach) { self = Self() }
    }
    func error(for binding: ShortcutBinding, action: GlobalShortcutAction) -> String? {
        if !binding.isValid { return "⌘・⌥・⌃ のどれかと一緒に押してください" }
        if binding.strokes.contains(where: \.isReserved) { return "システムで使われています" }
        // Fixed menu commands remain available except during an explicitly entered sequence.
        for stroke in binding.strokes.prefix(1) {
            if let title = Self.localShortcutTitle(stroke) { return "『\(title)』と同じキーです" }
        }
        for other in GlobalShortcutAction.allCases where other != action {
            if binding.overlaps(self[other]) { return "『\(other.title)』と同じキーです" }
        }
        return nil
    }

    /// Fixed application menu commands must remain usable while the browser is focused.
    private static func localShortcutTitle(_ stroke: ShortcutStroke) -> String? {
        if stroke.modifiers == .command {
            let titles = [43:"設定",6:"取り消す",7:"カット",8:"コピー",9:"ペースト",0:"すべてを選択",3:"ページ内を検索",17:"新規タブ",13:"タブを閉じる",37:"アドレスバー",15:"再読み込み",33:"戻る",30:"進む",24:"拡大",27:"縮小",29:"実際のサイズ"]
            if let title = titles[stroke.keyCode] { return title }
            if [18,19,20,21,23,22,26,28,25].contains(stroke.keyCode) { return "タブを選択" }
        }
        if stroke.modifiers == [.command,.shift] {
            return [6:"やり直す",17:"閉じたタブを戻す",46:"クイックメモ",0:"タブを検索",24:"拡大"][stroke.keyCode]
        }
        return nil
    }
}

protocol ShortcutRegistrar: AnyObject {
    func register(_ stroke: ShortcutStroke, action: @escaping () -> Void) -> Int?
    func unregister(_ token: Int)
}

/// All pending registrations have one owner and one cleanup path.
final class ShortcutSequenceMachine {
    private let registrar: ShortcutRegistrar
    private let now: () -> TimeInterval
    private var token: Int?
    private var deadline: TimeInterval?
    private(set) var pendingStroke: ShortcutStroke?
    private var generation = 0
    private let schedule: ((TimeInterval, @escaping () -> Void) -> (() -> Void))?
    private var cancelTimeout: (() -> Void)?
    var isPending: Bool { token != nil }
    init(registrar: ShortcutRegistrar, now: @escaping () -> TimeInterval,
         schedule: ((TimeInterval, @escaping () -> Void) -> (() -> Void))? = nil) {
        self.registrar = registrar; self.now = now; self.schedule = schedule
    }
    @discardableResult func begin(second: ShortcutStroke, action: @escaping () -> Void) -> Bool {
        cancel()
        let currentGeneration = generation
        deadline = now() + 0.8
        pendingStroke = second
        token = registrar.register(second) { [weak self] in
            guard let self, self.generation == currentGeneration, let deadline = self.deadline else { return }
            let accepted = self.now() < deadline
            self.cancel()
            if accepted { action() }
        }
        if token == nil { cancel(); return false }
        cancelTimeout = schedule?(0.8) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.tick()
        }
        return true
    }
    func tick() { if let deadline, now() >= deadline { cancel() } }
    func cancel() {
        generation += 1
        let oldToken = token
        token = nil; deadline = nil; pendingStroke = nil
        cancelTimeout?(); cancelTimeout = nil
        if let oldToken { registrar.unregister(oldToken) }
    }
    deinit { cancel() }
}

/// Owns both permanent prefixes and temporary second steps without any platform APIs.
final class ShortcutKeyMachine {
    private let registrar: ShortcutRegistrar
    private let now: () -> TimeInterval
    private let schedule: ((TimeInterval, @escaping () -> Void) -> (() -> Void))?
    private let action: (GlobalShortcutAction) -> Void
    private let registrationFailed: (GlobalShortcutAction) -> Void
    private let keyPressed: () -> Void
    private var preferences = ShortcutPreferences()
    private var prefixes: [GlobalShortcutAction:Int] = [:]
    private var enabled = false
    private lazy var sequence = ShortcutSequenceMachine(registrar: registrar, now: now, schedule: { [weak self] delay, callback in
        guard let self, let schedule = self.schedule else { return {} }
        return schedule(delay) { [weak self] in callback(); self?.restorePrefixes() }
    })

    init(registrar: ShortcutRegistrar, now: @escaping () -> TimeInterval,
         schedule: ((TimeInterval, @escaping () -> Void) -> (() -> Void))? = nil,
         action: @escaping (GlobalShortcutAction) -> Void,
         registrationFailed: @escaping (GlobalShortcutAction) -> Void = { _ in },
         keyPressed: @escaping () -> Void = {}) {
        self.registrar = registrar; self.now = now; self.schedule = schedule
        self.action = action; self.registrationFailed = registrationFailed
        self.keyPressed = keyPressed
    }

    func start(_ preferences: ShortcutPreferences) {
        guard !enabled || self.preferences != preferences else { return }
        stop()
        self.preferences = preferences; enabled = true
        restorePrefixes()
    }

    func stop() {
        enabled = false
        sequence.cancel()
        let old = prefixes.values
        prefixes = [:]
        old.forEach(registrar.unregister)
    }

    func cancelPending() { sequence.cancel(); restorePrefixes() }
    func localKeyDown(_ stroke: ShortcutStroke) {
        // Carbon and NSEvent may see the same key in either order. Let Carbon own registered keys.
        if sequence.pendingStroke == stroke || (enabled && GlobalShortcutAction.allCases.contains(where: { preferences[$0].strokes.first == stroke })) { return }
        cancelPending()
    }
    func tick() { sequence.tick(); restorePrefixes() }

    private func restorePrefixes() {
        guard enabled else { return }
        for id in GlobalShortcutAction.allCases where prefixes[id] == nil {
            guard let first = preferences[id].strokes.first else { continue }
            // For a repeated stroke sequence the prefix stays absent while step two owns it.
            if sequence.isPending && preferences[id].strokes == [first, first] { continue }
            var token: Int?
            token = registrar.register(first) { [weak self] in
                guard let self, let token, self.enabled, self.prefixes[id] == token else { return }
                self.acceptPrefix(id)
            }
            if let token { prefixes[id] = token } else { registrationFailed(id) }
        }
    }

    private func acceptPrefix(_ id: GlobalShortcutAction) {
        keyPressed()
        cancelPending()
        let keys = preferences[id].strokes
        if keys.count == 2 {
            if keys[0] == keys[1], let token = prefixes.removeValue(forKey: id) { registrar.unregister(token) }
            if !sequence.begin(second: keys[1], action: { [weak self] in
                guard let self else { return }
                self.keyPressed()
                self.cancelPending(); self.action(id)
            }) {
                restorePrefixes(); registrationFailed(id)
            }
        } else { action(id) }
    }

    deinit { stop() }
}

struct ModifierDoublePressMachine {
    static let maxPressDuration: TimeInterval = 0.3
    static let maxGap: TimeInterval = 0.4
    private enum State {
        case idle
        case pressed(ShortcutModifiers, started: TimeInterval, second: Bool)
        case waiting(ShortcutModifiers, released: TimeInterval)
    }
    private var held: ShortcutModifiers = []
    private var state: State = .idle
    mutating func update(_ flags: ShortcutModifiers, at time: TimeInterval, secureInput: Bool = false) -> ShortcutModifiers? {
        defer { held = flags }
        guard !secureInput else { interrupt(); return nil }
        guard flags != held else { return nil }
        if flags.isEmpty {
            guard case .pressed(let modifier, let started, let second) = state,
                  time >= started, time <= started + Self.maxPressDuration else {
                state = .idle
                return nil
            }
            if second {
                state = .idle
                return modifier
            }
            state = .waiting(modifier, released: time)
            return nil
        }
        guard held.isEmpty, flags.isSingle else {
            // A chord or modifier switch invalidates the entire press until all modifiers release.
            state = .idle
            return nil
        }
        var second = false
        if case .waiting(let modifier, let released) = state {
            second = modifier == flags && time >= released && time <= released + Self.maxGap
        }
        state = .pressed(flags, started: time, second: second)
        return nil
    }
    /// Ordinary key input invalidates the pending press but preserves physical modifier state.
    mutating func interrupt() { state = .idle }
    mutating func cancel(held flags: ShortcutModifiers = []) { state = .idle; held = flags }
}

enum ShortcutPermissionPolling {
    static func shouldRun(running: Bool, recording: Bool, hasDoublePress: Bool, needsPermission: Bool) -> Bool {
        running && !recording && hasDoublePress && needsPermission
    }
}

struct ShortcutRecordingMachine {
    private(set) var first: ShortcutStroke?
    private(set) var deadline: TimeInterval?
    mutating func key(_ stroke: ShortcutStroke, at time: TimeInterval) -> ShortcutBinding? {
        if let first {
            let binding: ShortcutBinding = time < (deadline ?? time) ? .keys([first, stroke]) : .keys([first])
            cancel(); return binding
        }
        first = stroke; deadline = time + 0.8; return nil
    }
    mutating func tick(at time: TimeInterval) -> ShortcutBinding? {
        guard let first, let deadline, time >= deadline else { return nil }
        cancel(); return .keys([first])
    }
    mutating func cancel() { first = nil; deadline = nil }
}
