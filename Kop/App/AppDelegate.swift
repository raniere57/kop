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
    /// Last shortcut that registered successfully.
    private var activeHotkey: HotkeyShortcut?
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
        center.addObserver(self, selector: #selector(handleHotkeyRecording(_:)), name: .hotkeyRecordingChanged, object: nil)
        center.addObserver(self, selector: #selector(handleOpenPreferencesNotification), name: .openPreferencesWindow, object: nil)
        center.addObserver(self, selector: #selector(applyTheme), name: .preferencesThemeChanged, object: nil)

        clipboardMonitor.start()
        warnIfStorageUnavailable()
    }

    /// Without a database every capture is dropped and the history stays
    /// empty, so say so once instead of failing silently.
    private func warnIfStorageUnavailable() {
        guard !persistence.isAvailable else { return }
        let alert = NSAlert()
        alert.messageText = "Não foi possível abrir o histórico"
        alert.informativeText = """
        O Kop não conseguiu abrir o banco de dados, então o histórico não será salvo. \
        Verifique as permissões da pasta:

        \(KopStorage.root.path)
        """
        alert.alertStyle = .critical
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotkeyManager?.unregister()
    }

    @objc private func handleShortcutChange() {
        let shortcut = preferences.hotkey
        guard shortcut != activeHotkey else { return }
        let previous = activeHotkey
        register(shortcut)
        if activeHotkey != shortcut, let previous {
            // Rejected: keep the old shortcut working and stored. Reverting the
            // preference re-enters here and stops at the guard above.
            hotkeyManager?.registerShortcut(previous)
            activeHotkey = previous
            preferences.hotkey = previous
        }
        statusItemController?.refreshMenuState()
    }

    /// The recorder pauses the global hotkey so pressing the current
    /// shortcut is recorded instead of toggling the panel.
    @objc private func handleHotkeyRecording(_ notification: Notification) {
        guard let hotkeyManager else { return }
        if notification.object as? Bool == true {
            hotkeyManager.unregister()
        } else if let activeHotkey {
            hotkeyManager.registerShortcut(activeHotkey)
        }
    }

    @objc private func handleOpenPreferencesNotification() {
        openPreferences()
    }

    @objc private func applyTheme() {
        NSApp.appearance = preferences.theme.appearance
    }

    private func register(_ shortcut: HotkeyShortcut) {
        guard let hotkeyManager else { return }
        if hotkeyManager.registerShortcut(shortcut) {
            activeHotkey = shortcut
        } else {
            let alert = NSAlert()
            alert.messageText = "Não foi possível registrar \(shortcut.displayString)"
            // HotkeyManager rejects modifier-less shortcuts (older versions
            // allowed Shift alone) before asking the system.
            alert.informativeText = shortcut.hasModifier
                ? "Outro app já usa esse atalho. Escolha outra combinação nas Preferências."
                : "O atalho precisa usar ⌘, ⌥ ou ⌃. Defina-o novamente nas Preferências."
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

        // VACUUM can take seconds: keep the main thread free. The panel (when
        // visible) and the Preferences stats (when its window is open) refresh
        // through the notification.
        let persistence = persistence
        Task {
            await runOffMain { persistence.clearNonFavoriteItems() }
            NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
        }
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
