import AppKit
import SwiftUI

/// Shared by the detail field and the list badge. The left circle is intentionally separate.
@MainActor struct NotionTaskStatusEditor: View {
    let task: NotionTask
    var compact = false
    var color: Color = .primary
    var detailFocus: FocusState<NotionTaskField?>.Binding? = nil
    @ObservedObject var store = NotionTasksStore.shared
    @State private var presented = false
    private var editable: Bool { store.canEdit(.status, task: task) }
    private var label: some View {
        HStack(spacing: 4) {
            Text(task.status.isEmpty ? "—" : task.status).lineLimit(1)
            if !compact && editable { Image(systemName: "chevron.down").font(.caption2) }
        }
        .font(compact ? .system(size: 10) : .body)
        .padding(.horizontal, compact ? 4 : 0).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(compact ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
    @ViewBuilder private var trigger: some View {
        if !compact, let detailFocus {
            NotionDetailFieldButton(field: .status, focus: detailFocus, enabled: editable,
                                   accessibilityLabel: "状態: \(task.status)",
                                   onOpen: { if editable { presented = true } },
                                   onTab: {
                                       if store.canEdit(.due, task: task) { detailFocus.wrappedValue = .due }
                                   }) { label }
        } else {
            Button { if editable { presented = true } } label: { label }
                .buttonStyle(.plain).disabled(!editable)
                .focusable(editable)
                .accessibilityLabel("状態: \(task.status)")
                .onKeyPress(.return) { if editable { presented = true; return .handled }; return .ignored }
                .onKeyPress(.space) { if editable { presented = true; return .handled }; return .ignored }
        }
    }
    var body: some View {
        trigger
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.statusOptions) { option in
                    Button {
                        guard editable else { return }
                        store.edit(page: task.id, value: .status(option)); presented = false
                    } label: {
                        HStack {
                            Text(option.name)
                            Spacer()
                            if option.name == task.status { Image(systemName: "checkmark") }
                        }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(6).frame(width: 180)
        }
        .onChange(of: editable) { _, value in if !value { presented = false } }
        .task {
            #if DEBUG
            if editable && task.id == "mock-0" && NotionTaskEditingPreview(rawValue: store.mockState ?? "") == (compact ? .listBadgeMenu : .detailStatusMenu) {
                try? await Task.sleep(for: .milliseconds(500)); presented = true
            }
            #endif
        }
    }
}

@MainActor struct NotionTaskDueEditor: View {
    let task: NotionTask
    var detailFocus: FocusState<NotionTaskField?>.Binding? = nil
    @ObservedObject var store = NotionTasksStore.shared
    @State private var presented = false
    private var editable: Bool { store.canEdit(.due, task: task) }
    private func choose(_ date: Date?) {
        guard editable else { return }
        store.edit(page: task.id, value: .due(date)); presented = false
    }
    private var label: some View {
        HStack(spacing: 5) {
            Text(task.due.map { NotionTaskRules.dateLabel($0) } ?? "—")
            if editable { Image(systemName: "calendar").font(.caption) }
        }
    }
    @ViewBuilder private var trigger: some View {
        if let detailFocus {
            NotionDetailFieldButton(field: .due, focus: detailFocus, enabled: editable,
                                   accessibilityLabel: "期日: \(task.due.map { NotionTaskRules.dateLabel($0) } ?? "期日なし")",
                                   onOpen: { if editable { presented = true } },
                                   onTab: {
                                       if store.canEdit(.status, task: task) { detailFocus.wrappedValue = .status }
                                   }) { label }
        } else {
            Button { if editable { presented = true } } label: { label }
                .buttonStyle(.plain).disabled(!editable).focusable(editable)
                .accessibilityLabel("期日: \(task.due.map { NotionTaskRules.dateLabel($0) } ?? "期日なし")")
                .onKeyPress(.return) { if editable { presented = true; return .handled }; return .ignored }
                .onKeyPress(.space) { if editable { presented = true; return .handled }; return .ignored }
        }
    }
    var body: some View {
        trigger
            .help(task.dueEditable == false ? "時刻または終了日を含む期日は Notion で編集してください" : "期日を変更")
            .background {
                NotionDueCalendarPopover(presented: $presented, date: task.due ?? Date(), onChoose: choose)
            }
            .onChange(of: editable) { _, value in if !value { presented = false } }
            .task {
                #if DEBUG
                if editable && NotionTaskEditingPreview(rawValue: store.mockState ?? "") == .dateCalendar {
                    try? await Task.sleep(for: .milliseconds(500)); presented = true
                }
                #endif
            }
    }
}

/// Preserve the approved SwiftUI label, using a native button as its sole input/AX target.
/// Native first-responder eligibility does not depend on Full Keyboard Access settings.
@MainActor private struct NotionDetailFieldButton<Label: View>: View {
    let field: NotionTaskField
    let focus: FocusState<NotionTaskField?>.Binding
    let enabled: Bool
    let accessibilityLabel: String
    let onOpen: () -> Void
    let onTab: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        label().accessibilityHidden(true).overlay {
            NotionDetailNativeButton(field: field, enabled: enabled, selected: focus.wrappedValue == field,
                                     accessibilityLabel: accessibilityLabel,
                                     onFocus: { focus.wrappedValue = field },
                                     onOpen: onOpen, onTab: onTab)
                .focused(focus, equals: field)
        }
    }
}

@MainActor private struct NotionDetailNativeButton: NSViewRepresentable {
    let field: NotionTaskField
    let enabled: Bool
    let selected: Bool
    let accessibilityLabel: String
    let onFocus: () -> Void
    let onOpen: () -> Void
    let onTab: () -> Void

    func makeNSView(context: Context) -> DetailKeyButton {
        let button = DetailKeyButton(frame: .zero)
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = button
        button.action = #selector(DetailKeyButton.activate)
        return button
    }
    func updateNSView(_ button: DetailKeyButton, context: Context) {
        button.field = field
        button.isEnabled = enabled
        button.setAccessibilityLabel(accessibilityLabel)
        button.onFocus = onFocus
        button.onOpen = onOpen
        button.onTab = onTab
        let newlySelected = selected && !button.focusRequested
        button.focusRequested = selected && enabled
        if newlySelected { button.requestNativeFocus() }
    }
    static func dismantleNSView(_ button: DetailKeyButton, coordinator: ()) {
        button.cancelTabHandoff()
    }

    @MainActor final class DetailKeyButton: NSButton {
        var field: NotionTaskField?
        var onFocus: (() -> Void)?
        var onOpen: (() -> Void)?
        var onTab: (() -> Void)?
        var focusRequested = false
        private var tabHandoffID: UUID?
        private var tabHandoffMonitor: Any?
        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool { isEnabled && !isHidden }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if focusRequested { requestNativeFocus() }
        }
        func requestNativeFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequested || self.tabHandoffID != nil, self.isEnabled,
                      let window = self.window, window.isKeyWindow else { return }
                if window.firstResponder !== self { window.makeFirstResponder(self) }
            }
        }
        override func becomeFirstResponder() -> Bool {
            guard isEnabled, super.becomeFirstResponder() else { return false }
            // FocusState updates must happen outside a representable update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder === self else { return }
                self.onFocus?()
            }
            return true
        }
        override func setAccessibilityFocused(_ focused: Bool) {
            if focused && isEnabled { window?.makeFirstResponder(self) }
            else { super.setAccessibilityFocused(focused) }
        }
        @objc func activate() {
            guard isEnabled else { return }
            cancelTabHandoff()
            window?.makeFirstResponder(self)
            onFocus?()
            onOpen?()
        }
        func cancelTabHandoff() {
            tabHandoffID = nil
            if let tabHandoffMonitor {
                NSEvent.removeMonitor(tabHandoffMonitor)
                self.tabHandoffMonitor = nil
            }
        }
        private func beginTabHandoff() {
            cancelTabHandoff()
            let handoff = UUID()
            tabHandoffID = handoff
            focusRequested = true
            requestNativeFocus()
            // Reassert the destination after the source's FocusState update has settled.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tabHandoffID == handoff,
                      self.window?.isKeyWindow == true else { return }
                self.onFocus?()
                self.requestNativeFocus()
            }
            // Bridge the next key if SwiftUI temporarily makes its hosting view the
            // responder. This monitor ends on the next input, not on an arbitrary timer.
            tabHandoffMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return event }
                    guard event.type == .keyDown, let window = self.window,
                          event.window === window, window.isKeyWindow, NSApp.keyWindow === window,
                          self.isEnabled, !self.isHiddenOrHasHiddenAncestor,
                          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                        self.cancelTabHandoff()
                        return event
                    }
                    // An explicit focus change to the other field takes precedence.
                    if let other = window.firstResponder as? DetailKeyButton, other !== self {
                        self.cancelTabHandoff()
                        return event
                    }
                    self.cancelTabHandoff()
                    guard [UInt16(48), 36, 76, 49].contains(event.keyCode) else { return event }
                    self.keyDown(with: event)
                    return nil
                }
            }
        }
        private func otherDetailField(in view: NSView) -> DetailKeyButton? {
            if let button = view as? DetailKeyButton, button !== self,
               button.field != field, button.isEnabled, !button.isHiddenOrHasHiddenAncestor { return button }
            for child in view.subviews {
                if let button = otherDetailField(in: child) { return button }
            }
            return nil
        }
        override func keyDown(with event: NSEvent) {
            guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                super.keyDown(with: event); return
            }
            switch event.keyCode {
            case 48:
                // Synchronize logical focus and the actual responder in this same key event.
                // With two fields, Tab and Shift-Tab share the same other target.
                onTab?()
                if let root = window?.contentView, let other = otherDetailField(in: root) {
                    window?.makeFirstResponder(other)
                    other.beginTabHandoff()
                }
            case 36, 76, 49: activate() // Return, keypad Enter, Space.
            default: super.keyDown(with: event)
            }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, isEnabled,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  [UInt16(48), 36, 76, 49].contains(event.keyCode) else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }
    }
}

/// An AppKit popover avoids SwiftUI hosting minimum widths around the native calendar.
@MainActor private struct NotionDueCalendarPopover: NSViewRepresentable {
    @Binding var presented: Bool
    let date: Date
    let onChoose: (Date?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        anchor.focusRingType = .none
        return anchor
    }
    func updateNSView(_ anchor: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.picker?.suppressRing()
        if presented {
            // Wait until the SwiftUI anchor has a window, without changing other windows focus.
            DispatchQueue.main.async { [weak anchor, weak coordinator = context.coordinator] in
                guard let anchor, anchor.window != nil, let coordinator, coordinator.parent.presented else { return }
                coordinator.show(relativeTo: anchor)
            }
        } else { context.coordinator.close() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: NotionDueCalendarPopover
        private let popover = NSPopover()
        fileprivate var picker: RinglessDuePicker?
        private var tabMonitor: Any?
        init(parent: NotionDueCalendarPopover) { self.parent = parent }

        func show(relativeTo anchor: NSView) {
            guard !popover.isShown else { return }
            let picker = RinglessDuePicker(frame: .zero)
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = .yearMonthDay
            picker.datePickerMode = .single
            picker.locale = Locale(identifier: "ja_JP")
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = picker.locale
            calendar.firstWeekday = 1
            picker.calendar = calendar
            picker.dateValue = parent.date
            picker.suppressRing()
            picker.setAccessibilityLabel("期日")
            picker.target = self
            picker.action = #selector(changed(_:))
            self.picker = picker

            // Use the native fitting size, never sizeToFit/frame defaults or a hosting-view minimum.
            let calendarSize = picker.fittingSize
            let inset: CGFloat = 8
            let rowHeight: CGFloat = 22
            let gap: CGFloat = 6
            let size = NSSize(width: calendarSize.width + inset * 2,
                              height: calendarSize.height + rowHeight + gap + inset * 2)
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.autoresizesSubviews = false
            content.focusRingType = .none
            picker.frame = NSRect(x: inset, y: inset + rowHeight + gap,
                                  width: calendarSize.width, height: calendarSize.height)
            content.addSubview(picker)

            let buttons = ["今日", "明日", "期日なし"].enumerated().map { index, title in
                let button = NSButton(title: title, target: self, action: #selector(quickDate(_:)))
                button.tag = index
                button.isBordered = false
                button.font = .systemFont(ofSize: 11)
                button.contentTintColor = .linkColor
                button.focusRingType = .none
                let textWidth = (title as NSString).size(withAttributes: [.font: button.font!]).width
                button.setFrameSize(NSSize(width: ceil(textWidth) + 6, height: rowHeight))
                return button
            }
            let totalWidth = buttons.reduce(CGFloat.zero) { $0 + $1.frame.width }
            let spacing = max(0, (calendarSize.width - totalWidth) / 2)
            var x = inset
            for button in buttons {
                button.frame = NSRect(x: x, y: inset, width: button.frame.width, height: rowHeight)
                content.addSubview(button)
                x += button.frame.width + spacing
            }
            picker.nextKeyView = buttons[0]
            buttons[0].nextKeyView = buttons[1]
            buttons[1].nextKeyView = buttons[2]
            buttons[2].nextKeyView = picker
            let controller = NSViewController()
            controller.view = content
            controller.preferredContentSize = size
            popover.delegate = self
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.contentSize = size
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            clearInitialCalendarFocus()
            // acceptsFirstResponder stays false until an actual Tab (or pointer) interaction.
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak picker] event in
                // AppKit invokes local event monitors on the main thread. Preserve the
                // synchronous event result while explicitly restoring actor isolation.
                MainActor.assumeIsolated {
                    guard let self, let picker, self.popover.isShown,
                          event.keyCode == 48, let window = picker.window,
                          event.window === window, NSApp.keyWindow === window else { return event }
                    guard !picker.allowsKeyboardFocus else { return event }
                    picker.allowsKeyboardFocus = true
                    picker.suppressRing()
                    if event.modifierFlags.contains(.shift) { window.makeFirstResponder(buttons[2]) }
                    else { window.makeFirstResponder(picker) }
                    return nil
                }
            }
        }
        func close() {
            popover.performClose(nil)
            removeMonitor()
            picker = nil
        }
        private func clearInitialCalendarFocus() {
            guard let picker, !picker.allowsKeyboardFocus else { return }
            picker.window?.makeFirstResponder(nil)
            picker.suppressRing()
            picker.needsDisplay = true
        }
        func popoverDidShow(_ notification: Notification) {
            // AppKit may assign initial focus again as the presentation finishes.
            // Do not displace focus after a user's Tab or click interaction.
            clearInitialCalendarFocus()
        }
        func popoverDidClose(_ notification: Notification) {
            removeMonitor()
            picker = nil
            if parent.presented { parent.presented = false }
        }
        private func removeMonitor() {
            if let tabMonitor { NSEvent.removeMonitor(tabMonitor); self.tabMonitor = nil }
        }
        @objc private func changed(_ sender: NSDatePicker) { parent.onChoose(sender.dateValue) }
        @objc private func quickDate(_ sender: NSButton) {
            switch sender.tag {
            case 0: parent.onChoose(Calendar.current.startOfDay(for: Date()))
            case 1: parent.onChoose(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())))
            default: parent.onChoose(nil)
            }
        }
    }
}

@MainActor private final class RinglessDuePicker: NSDatePicker {
    var allowsKeyboardFocus = false
    override var acceptsFirstResponder: Bool { allowsKeyboardFocus && super.acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}
    func suppressRing() {
        focusRingType = .none
        cell?.focusRingType = .none
        isBordered = false
        isBezeled = false
        drawsBackground = false
    }
    override func becomeFirstResponder() -> Bool {
        suppressRing()
        return allowsKeyboardFocus && super.becomeFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
        allowsKeyboardFocus = true
        suppressRing()
        super.mouseDown(with: event)
    }
}

@MainActor struct NotionTaskDetailSaveNotice: View {
    let page: String
    let onOpenSettings: () -> Void
    @ObservedObject var store = NotionTasksStore.shared
    @Environment(\.colorScheme) private var scheme
    // sRGB #BDBDBD on #242424 is 8.26:1 (also >4.5:1 on #444444).
    static let textColor = Color(red: 189.0 / 255, green: 189.0 / 255, blue: 189.0 / 255)
    private var failure: NotionTaskWriteFailure? {
        store.writeFailures[page]?[.status] ?? store.writeFailures[page]?[.due]
    }
    private func retry() {
        if let failure { store.retryWrite(page: page, field: failure.value.field) }
        else { store.resetWritePermission() }
    }
    var body: some View {
        if store.noPermission {
            VStack(alignment: .leading, spacing: 6) {
                Text("編集するには Notion で『Update content』をオンにしてください")
                    .foregroundStyle(scheme == .dark ? Self.textColor : Color(white: 0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button("設定を開く", action: onOpenSettings)
                    Button("再試行", action: retry)
                }.buttonStyle(.link).foregroundStyle(.blue).fixedSize()
            }.font(.body)
        } else if let failure {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Notion に保存できませんでした")
                    .foregroundStyle(scheme == .dark ? Self.textColor : Color(white: 0.35))
                    .help(failure.text)
                Button("再試行", action: retry)
                    .buttonStyle(.link).foregroundStyle(.blue).fixedSize()
            }.font(.body).fixedSize(horizontal: true, vertical: false)
        }
    }
}
