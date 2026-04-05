import AppKit

final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelAction: () -> Void
    private let clearAction: () -> Void
    private let preferencesAction: () -> Void
    private let pauseAction: () -> Void
    private let quitAction: () -> Void
    private let isPaused: () -> Bool

    init(
        panelAction: @escaping () -> Void,
        clearAction: @escaping () -> Void,
        preferencesAction: @escaping () -> Void,
        pauseAction: @escaping () -> Void,
        quitAction: @escaping () -> Void,
        isPaused: @escaping () -> Bool
    ) {
        self.panelAction = panelAction
        self.clearAction = clearAction
        self.preferencesAction = preferencesAction
        self.pauseAction = pauseAction
        self.quitAction = quitAction
        self.isPaused = isPaused
        super.init()
        configureStatusItem()
    }

    func refreshMenuState() {
        statusItem.menu = makeMenu()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Kop")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshMenuState()
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panelAction()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Abrir Kop", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Limpar histórico", action: #selector(clearHistory), keyEquivalent: "")
        let pauseTitle = isPaused() ? "Retomar monitoramento" : "Pausar monitoramento"
        menu.addItem(withTitle: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferências", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair", action: #selector(quitApp), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func openPanel() { panelAction() }
    @objc private func clearHistory() { clearAction() }
    @objc private func togglePause() { pauseAction(); refreshMenuState() }
    @objc private func openPreferences() { preferencesAction() }
    @objc private func quitApp() { quitAction() }
}
