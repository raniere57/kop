import AppKit
import Combine
import SwiftUI

final class KopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
    }
}

@MainActor
final class PanelController: NSWindowController, NSWindowDelegate {
    private enum Key {
        static let escape: UInt16 = 53
        static let arrowDown: UInt16 = 125
        static let arrowUp: UInt16 = 126
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
    }

    private let viewModel: ClipboardHistoryViewModel
    private let preferences: PreferencesStore
    private var keyMonitor: Any?
    private let scrollStepper = ScrollStepper()
    private var expansionCancellable: AnyCancellable?
    private var collapsedFrame: NSRect?

    init(viewModel: ClipboardHistoryViewModel, preferences: PreferencesStore) {
        self.viewModel = viewModel
        self.preferences = preferences

        let contentView = KopPanelView(viewModel: viewModel, preferences: preferences)
        let hosting = NSHostingView(rootView: contentView)

        let panel = KopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.contentMinSize = NSSize(width: 400, height: 320)
        panel.contentView = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.masksToBounds = true

        super.init(window: panel)
        panel.delegate = self
        applyTheme()

        // Expanding an image grows the panel so the picture is actually big.
        expansionCancellable = viewModel.$expandedItem
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                self?.setExpandedLayout(isExpanded, animated: true)
            }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePanel),
            name: .closeClipboardPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyTheme),
            name: .preferencesThemeChanged,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    @objc func closePanel() {
        removeKeyMonitor()
        guard let window, window.isVisible else { return }
        // Restore the small frame before hiding, otherwise the panel reopens
        // at the expanded size.
        setExpandedLayout(false, animated: false)
        viewModel.collapse()
        window.orderOut(nil)
        viewModel.isPanelVisible = false
        viewModel.searchText = ""
        viewModel.listFilter = .all
    }

    @objc private func applyTheme() {
        window?.appearance = preferences.theme.appearance
    }

    func windowDidResignKey(_ notification: Notification) {
        // Keep the panel alive while a sheet/alert it opened is on screen
        // (renaming a favourite, confirming a deletion).
        guard NSApp.modalWindow == nil, !isPreferencesWindowKey else { return }
        closePanel()
    }

    private var isPreferencesWindowKey: Bool {
        NSApp.keyWindow?.identifier?.rawValue == "preferencesWindow"
    }

    private func showPanel() {
        guard let panel = window as? NSPanel else { return }
        // Opened over one of Kop's own windows there is no app to paste into;
        // a target left from an earlier open would receive the paste instead.
        let frontmost = NSWorkspace.shared.frontmostApplication
        viewModel.pasteTargetApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        viewModel.isPanelVisible = true
        viewModel.reloadForShow()
        position(panel: panel)

        let finalFrame = panel.frame
        let initialFrame = finalFrame.insetBy(dx: finalFrame.width * 0.02, dy: finalFrame.height * 0.02)

        panel.alphaValue = 0
        panel.setFrame(initialFrame, display: false)
        installKeyMonitor()
        panel.orderFrontRegardless()
        panel.makeKey()
        if let field = panel.contentView?.firstDescendant(matching: SearchFieldIdentifier) {
            panel.makeFirstResponder(field)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    /// Opens on the screen holding the pointer, slightly above the optical
    /// centre so the list reads naturally.
    private func position(panel: NSPanel) {
        let cursorLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursorLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2 + visible.height * 0.08).rounded()
        )
        panel.setFrameOrigin(origin)
    }

    private func setExpandedLayout(_ isExpanded: Bool, animated: Bool) {
        guard let window, window.isVisible else { return }

        let targetFrame: NSRect
        if isExpanded {
            guard collapsedFrame == nil else { return }
            collapsedFrame = window.frame
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = NSSize(
                width: min(visible.width * 0.7, 1040),
                height: min(visible.height * 0.78, 780)
            )
            targetFrame = NSRect(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.midY - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            )
        } else {
            guard let previous = collapsedFrame else { return }
            collapsedFrame = nil
            targetFrame = previous
        }

        guard animated else {
            window.setFrame(targetFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Keyboard

    /// The search field owns first responder, so panel-wide shortcuts are
    /// handled here instead of in the SwiftUI hierarchy.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel {
                return self.handleScroll(event) ? nil : event
            }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Two-finger scrolling walks through the images, but only while one is
    /// expanded — otherwise the list must keep scrolling normally.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard viewModel.expandedItem != nil else { return false }
        switch scrollStepper.step(for: event) {
        case .previous: viewModel.stepExpanded(by: -1)
        case .next: viewModel.stepExpanded(by: 1)
        case nil: break
        }
        return true
    }

    private func handleExpanded(_ event: NSEvent, command: Bool) -> Bool {
        switch event.keyCode {
        case Key.escape:
            viewModel.collapse()
            return true
        case Key.arrowUp:
            viewModel.stepExpanded(by: -1)
            return true
        case Key.arrowDown:
            viewModel.stepExpanded(by: 1)
            return true
        case Key.returnKey, Key.keypadEnter:
            viewModel.copyExpanded(autoPaste: preferences.pasteOnSelect)
            return true
        default:
            break
        }
        if command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            viewModel.copyExpanded(autoPaste: false)
            return true
        }
        return false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        guard NSApp.keyWindow === window else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        // While an image is expanded it owns the keyboard.
        if viewModel.expandedItem != nil, handleExpanded(event, command: command) {
            return true
        }

        switch event.keyCode {
        case Key.escape:
            NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
            return true
        case Key.arrowDown:
            viewModel.selectNext()
            return true
        case Key.arrowUp:
            viewModel.selectPrevious()
            return true
        case Key.returnKey, Key.keypadEnter:
            viewModel.activateSelectedItem(plainTextOnly: shift)
            return true
        // With text in the search field, ⌘⌫ belongs to the field ("delete to
        // start of line"). Favorites are never deleted by the shortcut.
        case Key.delete where command && viewModel.searchText.isEmpty:
            if viewModel.selectedItem?.isFavorite == true {
                NSSound.beep()
            } else {
                viewModel.deleteSelected()
            }
            return true
        default:
            break
        }

        guard command, let characters = event.charactersIgnoringModifiers else { return false }
        switch characters.lowercased() {
        case "d":
            viewModel.toggleFavoriteSelected()
            return true
        case "y":
            viewModel.previewSelected()
            return true
        case "1"..."9":
            guard let index = Int(characters) else { return false }
            viewModel.activateItem(at: index - 1)
            return true
        default:
            return false
        }
    }
}
