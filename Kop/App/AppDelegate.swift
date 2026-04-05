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
        statusItemController = StatusItemController(
            panelAction: { [weak self] in self?.togglePanel() },
            clearAction: { [weak self] in self?.clearHistory() },
            preferencesAction: { [weak self] in self?.openPreferences() },
            pauseAction: { [weak self] in self?.toggleMonitoring() },
            quitAction: { NSApp.terminate(nil) },
            isPaused: { [weak self] in self?.clipboardMonitor.isPaused ?? false }
        )

        panelController = PanelController(
            viewModel: panelViewModel,
            preferences: preferences
        )

        hotkeyManager = HotkeyManager()
        hotkeyManager?.onHotkey = { [weak self] in
            self?.togglePanel()
        }
        hotkeyManager?.registerShortcut(preferences.hotkey)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutChange),
            name: .preferencesHotkeyChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenPreferencesNotification),
            name: .openPreferencesWindow,
            object: nil
        )

        clipboardMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotkeyManager?.unregister()
    }

    @objc private func handleShortcutChange() {
        hotkeyManager?.registerShortcut(preferences.hotkey)
    }

    @objc private func handleOpenPreferencesNotification() {
        openPreferences()
    }

    private func togglePanel() {
        panelController?.toggle()
    }

    private func clearHistory() {
        persistence.clearNonFavoriteItems()
        panelViewModel.reload()
    }

    private func openPreferences() {
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
