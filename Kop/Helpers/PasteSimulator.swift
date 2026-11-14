import AppKit
import ApplicationServices

enum PasteSimulator {
    private static let vKeyCode: CGKeyCode = 0x09

    static func simulatePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// Auto-paste needs the Accessibility permission. Without it macOS silently
/// drops the synthetic keystroke, so tell the user instead of failing quietly.
@MainActor
enum AccessibilityPermission {
    private static var alertShown = false

    static var isGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func ensureGranted() -> Bool {
        if isGranted {
            alertShown = false
            return true
        }
        guard !alertShown else { return false }
        alertShown = true

        let alert = NSAlert()
        alert.messageText = "Kop precisa de permissão de Acessibilidade"
        alert.informativeText = """
        Para colar automaticamente no app ativo, autorize o Kop em \
        Ajustes do Sistema → Privacidade e Segurança → Acessibilidade.

        O item já foi copiado — você pode colar com ⌘V.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }
}
