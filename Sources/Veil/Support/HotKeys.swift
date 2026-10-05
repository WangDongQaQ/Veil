import Carbon.HIToolbox

/// System-wide shortcuts through the Carbon hot-key API — needs no Accessibility permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)
    static let command = UInt32(cmdKey)

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    @discardableResult
    func register(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5645_494C), id: id)   // 'VEIL'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
