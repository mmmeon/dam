//
//  GlobalHotkey.swift
//
//  Registers system-wide hotkeys via Carbon's RegisterEventHotKey.
//  No Accessibility permission required. Supports multiple simultaneous
//  instances — each gets a unique ID so the shared event handler can
//  dispatch to the right callback.
//

import AppKit
import Carbon.HIToolbox

// MARK: - Shared handler (installed once, dispatches by hotkey ID)

private var _sharedHandlerRef: EventHandlerRef?
private var _hotkeyActions: [UInt32: () -> Void] = [:]
private var _nextHotkeyID: UInt32 = 1

private func _hotkeyEventHandler(
    _ handlerRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hkID = EventHotKeyID()
    _ = withUnsafeMutablePointer(to: &hkID) {
        GetEventParameter(event,
                          EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID),
                          nil,
                          MemoryLayout<EventHotKeyID>.size,
                          nil,
                          $0)
    }
    _hotkeyActions[hkID.id]?()
    return noErr
}

private func ensureSharedHandlerInstalled() {
    guard _sharedHandlerRef == nil else { return }
    var et = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(GetApplicationEventTarget(),
                        _hotkeyEventHandler,
                        1, &et, nil, &_sharedHandlerRef)
}

// MARK: -

final class GlobalHotkey {

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// Registers `preference` as a system-wide hotkey. `action` is called on
    /// the main thread each time it fires.
    init(preference: HotkeyPreference, action: @escaping () -> Void) {
        ensureSharedHandlerInstalled()
        id = _nextHotkeyID
        _nextHotkeyID += 1
        _hotkeyActions[id] = { DispatchQueue.main.async { action() } }
        register(preference)
    }

    /// Re-registers with a new key binding (call after the user changes the shortcut).
    func update(preference: HotkeyPreference) {
        register(preference)
    }

    private func register(_ pref: HotkeyPreference) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let sig  = AppIdentity.fourCharCode
        let hkID = EventHotKeyID(signature: sig, id: id)
        RegisterEventHotKey(pref.keyCode, pref.modifiers, hkID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        _hotkeyActions.removeValue(forKey: id)
    }
}
