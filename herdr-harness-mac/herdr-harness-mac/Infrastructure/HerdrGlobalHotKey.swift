import Carbon.HIToolbox

/// A small, sandbox-safe wrapper around Carbon's process-wide hot-key API.
@MainActor
final class HerdrGlobalHotKey {
    private static let signature: OSType = 0x4848_5544 // "HHUD"

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: @MainActor () -> Void
    // Carbon dispatches and normally accesses these opaque references on the main thread.
    // `deinit` is a best-effort cleanup path and is nonisolated under Swift 6.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    func register() -> Bool {
        if hotKeyRef != nil { return true }

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetEventDispatcherTarget(),
                herdrGlobalHotKeyEventHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            guard status == noErr else { return false }
        }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        return true
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    fileprivate func invoke() {
        handler()
    }
}

private nonisolated func herdrGlobalHotKeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == 0x4848_5544, identifier.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }

    let hotKey = Unmanaged<HerdrGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        hotKey.invoke()
    }
    return noErr
}
