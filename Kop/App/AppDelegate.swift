import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let persistence = PersistenceManager.shared
    private let preferences = PreferencesStore.shared
    private lazy var clipboardMonitor = ClipboardMonitor(
        persistence: persistence,
        preferences: preferences
    )
    private lazy var panelViewModel = ClipboardHistoryViewModel(
        persistence: persistence,
        preferences: preferences,
        clipboardMonitor: clipboardMonitor
    )
    lazy var preferencesViewModel = PreferencesViewModel(preferences: preferences)

    private var statusItemController: StatusItemController?
    private var hotkeyManager: HotkeyManager?
    private var panelController: PanelController?
    private lazy var preferencesWindowController = PreferencesWindowController(viewModel: preferencesViewModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()

        statusItemController = StatusItemController(
            panelAction: { [weak self] in self?.togglePanel() },
            clearAction: { [weak self] in self?.clearHistory() },
            preferencesAction: { [weak self] in self?.openPreferences() },
            pauseAction: { [weak self] in self?.toggleMonitoring() },
            quitAction: { NSApp.terminate(nil) },
            isPaused: { [weak self] in self?.clipboardMonitor.isPaused ?? false },
            hotkeyDescription: { [weak self] in self?.preferences.hotkey.displayString ?? "" }
        )

        panelController = PanelController(viewModel: panelViewModel, preferences: preferences)

        hotkeyManager = HotkeyManager()
        hotkeyManager?.onHotkey = { [weak self] in self?.togglePanel() }
        register(preferences.hotkey)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleShortcutChange), name: .preferencesHotkeyChanged, object: nil)
        center.addObserver(self, selector: #selector(handleOpenPreferencesNotification), name: .openPreferencesWindow, object: nil)
        center.addObserver(self, selector: #selector(applyTheme), name: .preferencesThemeChanged, object: nil)

        clipboardMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotkeyManager?.unregister()
    }

    @objc private func handleShortcutChange() {
        register(preferences.hotkey)
        statusItemController?.refreshMenuState()
    }

    @objc private func handleOpenPreferencesNotification() {
        openPreferences()
    }

    @objc private func applyTheme() {
        NSApp.appearance = preferences.theme.appearance
    }

    private func register(_ shortcut: HotkeyShortcut) {
        guard let hotkeyManager else { return }
        if !hotkeyManager.registerShortcut(shortcut) {
            let alert = NSAlert()
            alert.messageText = "Não foi possível registrar \(shortcut.displayString)"
            alert.informativeText = "Outro app já usa esse atalho. Escolha outra combinação nas Preferências."
            alert.alertStyle = .warning
            alert.runModal()
            openPreferences()
        }
    }

    private func togglePanel() {
        panelController?.toggle()
    }

    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Limpar histórico?"
        alert.informativeText = "Todos os itens não favoritados serão removidos. Esta ação não pode ser desfeita."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Limpar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        persistence.clearNonFavoriteItems()
        panelViewModel.reload()
    }

    private func openPreferences() {
        // The panel floats above normal windows, so it has to go before the
        // preferences window can be seen.
        panelController?.closePanel()
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController.show()
    }

    private func toggleMonitoring() {
        if clipboardMonitor.isPaused {
            clipboardMonitor.resume()
        } else {
            clipboardMonitor.pause()
        }
        statusItemController?.refreshMenuState()
    }
}
