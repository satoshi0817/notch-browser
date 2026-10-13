import Carbon

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private let id: EventHotKeyID
    private let action: () -> Void
    private(set) var registered = false
    private var active = true

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = EventHotKeyID(signature: OSType(0x4E54_4348), id: Self.nextID)
        Self.nextID += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var received = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  received.signature == hotKey.id.signature, received.id == hotKey.id.id else { return OSStatus(eventNotHandledErr) }
            // Application-target Carbon handlers run on the main event loop. Register a
            // sequence's second step before returning, without another main-queue turn.
            guard hotKey.active else { return noErr }
            hotKey.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        guard handlerStatus == noErr else { return }
        registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    func invalidate() {
        active = false
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
    deinit { invalidate() }
}
