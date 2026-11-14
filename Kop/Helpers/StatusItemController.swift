import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelAction: () -> Void
    private let clearAction: () -> Void
    private let preferencesAction: () -> Void
    private let pauseAction: () -> Void
    private let quitAction: () -> Void
    private let isPaused: () -> Bool
    private let hotkeyDescription: () -> String

    init(
        panelAction: @escaping () -> Void,
        clearAction: @escaping () -> Void,
        preferencesAction: @escaping () -> Void,
        pauseAction: @escaping () -> Void,
        quitAction: @escaping () -> Void,
        isPaused: @escaping () -> Bool,
        hotkeyDescription: @escaping () -> String
    ) {
        self.panelAction = panelAction
        self.clearAction = clearAction
        self.preferencesAction = preferencesAction
        self.pauseAction = pauseAction
        self.quitAction = quitAction
        self.isPaused = isPaused
        self.hotkeyDescription = hotkeyDescription
        super.init()
        configureStatusItem()
    }

    func refreshMenuState() {
        guard let button = statusItem.button else { return }
        let paused = isPaused()
        button.image = NSImage(
            systemSymbolName: paused ? "clipboard.fill" : "clipboard",
            accessibilityDescription: paused ? "Kop (pausado)" : "Kop"
        )
        button.appearsDisabled = paused
        button.toolTip = paused
            ? "Kop — monitoramento pausado"
            : "Kop — \(hotkeyDescription()) para abrir"
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshMenuState()
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
        guard wantsMenu else {
            panelAction()
            return
        }
        // Attaching the menu only for this click keeps left-click opening the panel.
        let menu = makeMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Abrir Kop", action: #selector(openPanel), keyEquivalent: "")
        open.toolTip = hotkeyDescription()
        menu.addItem(withTitle: isPaused() ? "Retomar monitoramento" : "Pausar monitoramento", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Limpar histórico…", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Preferências…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair do Kop", action: #selector(quitApp), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func openPanel() { panelAction() }
    @objc private func clearHistory() { clearAction() }
    @objc private func togglePause() { pauseAction() }
    @objc private func openPreferences() { preferencesAction() }
    @objc private func quitApp() { quitAction() }
}
