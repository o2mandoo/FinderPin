import Carbon
import Foundation

/// System-wide hotkeys via Carbon RegisterEventHotKey (needs no extra permission).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4650_494E), id: id) // 'FPIN'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                  GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = HotKeyCenter.shared.actions[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Runtime switch for macOS's own symbolic hotkeys (the ones in System Settings ▸
/// Keyboard Shortcuts). System shortcuts win over RegisterEventHotKey, so ⌥⌘Space
/// ("Show Finder search window", id 65) must be turned off while FinderPin owns it.
/// The change is per login session and is reverted when FinderPin quits.
enum SymbolicHotKeys {
    static let finderSearchWindow: Int32 = 65

    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private static let setEnabledFn: SetEnabledFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(sym, to: SetEnabledFn.self)
    }()

    @discardableResult
    static func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool {
        guard let fn = setEnabledFn else { return false }
        return fn(id, enabled) == 0
    }
}
