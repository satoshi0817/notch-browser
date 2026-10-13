import AppKit
import SwiftUI
import Carbon

final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: GlobalShortcutAction?
    @Published private(set) var first: ShortcutStroke?
    @Published private(set) var errors: [GlobalShortcutAction:String] = [:]
    @Published private(set) var attempted: [GlobalShortcutAction:ShortcutBinding] = [:]
    private let controller: ShortcutController
    init(controller: ShortcutController = .shared) { self.controller = controller }
    private var machine = ShortcutRecordingMachine()
    private var doublePress = ModifierDoublePressMachine()
    private var monitor: Any?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    func begin(_ action: GlobalShortcutAction) {
        cancel()
        errors[action] = nil; attempted[action] = nil
        recording = action
        controller.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, self.recording != nil else { return event }
            let time = ProcessInfo.processInfo.systemUptime
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown { self.cancel(); return event }
            if event.type == .keyUp || event.type == .scrollWheel { self.doublePress.interrupt(); return event }
            if event.type == .flagsChanged {
                if self.first == nil, let modifier = self.doublePress.update(ShortcutModifiers(event.modifierFlags), at: time, secureInput: IsSecureEventInputEnabled()) {
                    self.finish(.doubleModifier(modifier))
                }
                return nil
            }
            self.doublePress.interrupt()
            guard !event.isARepeat else { return nil }
            if event.keyCode == 53 { self.cancel(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { self.finish(.unassigned); return nil }
            let stroke = ShortcutStroke(keyCode: Int(event.keyCode), modifiers: ShortcutModifiers(event.modifierFlags))
            if !stroke.isValid || stroke.isReserved { self.finish(.keys([stroke])); return nil }
            if let binding = self.machine.key(stroke, at: time) { self.finish(binding) }
            else { self.first = stroke }
            return nil
        }
        timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let binding = self.machine.tick(at: ProcessInfo.processInfo.systemUptime) { self.finish(binding) }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
    }
    func finish(_ binding: ShortcutBinding) {
        guard let action = recording else { return }
        // Leave runtime suspended until the candidate has been checked and persisted.
        cleanup()
        if let error = controller.set(binding, for: action) {
            errors[action] = error; attempted[action] = binding
            observeErrorDismissal()
        } else { errors[action] = nil; attempted[action] = nil }
        controller.suspend(false)
    }
    private func cleanup() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        timer?.invalidate(); timer = nil
        machine.cancel(); doublePress.cancel(); first = nil; recording = nil
    }
    /// Next interaction or focus loss dismisses rejected candidates without changing saved settings.
    func dismissErrors() {
        errors = [:]; attempted = [:]
        if recording == nil {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        }
    }
    private func observeErrorDismissal() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.dismissErrors()
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.dismissErrors()
        }
    }
    func cancel() { cleanup(); dismissErrors(); controller.suspend(false) }
    func reset(_ action: GlobalShortcutAction) {
        cancel()
        errors[action] = controller.set(action.defaultBinding, for: action)
        attempted[action] = nil
        if errors[action] != nil { observeErrorDismissal() }
    }
    func resetAll() { cancel(); errors = [:]; attempted = [:]; controller.resetAll() }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
        if recording != nil { controller.suspend(false) }
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var controller = ShortcutController.shared
    @ObservedObject var recorder: ShortcutRecorder
    var body: some View {
        ForEach(GlobalShortcutAction.allCases) { action in
            let binding = store.data.shortcuts[action]
            let active = recorder.recording == action
            let error = recorder.errors[action] ?? controller.errors[action]
            let presentation = ShortcutRowPresentation(saved: binding, attempted: recorder.attempted[action], error: error)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(action.title)
                    Spacer()
                    Button { recorder.begin(action) } label: {
                        HStack(spacing: 6) {
                            if active {
                                Text(recorder.first.map { $0.display + "  続けて押せます" } ?? "キーを押してください")
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.blue, lineWidth: 2))
                            } else {
                                ForEach(Array(presentation.caps.enumerated()), id: \.offset) { _, cap in
                                    Text(cap).font(.system(.body, design: .monospaced))
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(error != nil ? Color.red : Color.secondary.opacity(0.3), lineWidth: error != nil ? 2 : 1))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title + "のキーを登録")
                    if binding != action.defaultBinding {
                        Button("↺") { recorder.reset(action) }.help("既定に戻す")
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if let warning = presentation.note { Text(warning).font(.caption).foregroundStyle(.secondary) }
                if case .doubleModifier = binding, controller.needsPermission {
                    HStack {
                        Text("修飾キーの2回押しには入力監視の許可が必要です").font(.caption).foregroundStyle(.secondary)
                        Button("許可を開く") {
                            // Permission requests belong to this explicit action, never a save/reset transaction.
                            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                    }
                }
            }
        }
    }
}
