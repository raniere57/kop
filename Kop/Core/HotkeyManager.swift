import AppKit
import Carbon
import Foundation

final class HotkeyManager {
    var onHotkey: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Returns false when the combination is already taken by another app, so
    /// the caller can tell the user instead of leaving a dead shortcut.
    @discardableResult
    func registerShortcut(_ shortcut: HotkeyShortcut) -> Bool {
        unregister()
        guard shortcut.hasModifier else { return false }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            guard status == noErr, hotkeyID.id == 1 else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onHotkey?() }
            return noErr
        }, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandler)

        guard handlerStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4F5021), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if status != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
