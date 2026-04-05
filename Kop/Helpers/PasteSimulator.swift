import AppKit

enum PasteSimulator {
    static func simulatePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        commandDown?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        commandUp?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }
}
