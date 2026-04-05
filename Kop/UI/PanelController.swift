import AppKit
import SwiftUI

final class KopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSWindowController, NSWindowDelegate {
    private let viewModel: ClipboardHistoryViewModel
    private let preferences: PreferencesStore

    init(viewModel: ClipboardHistoryViewModel, preferences: PreferencesStore) {
        self.viewModel = viewModel
        self.preferences = preferences

        let contentView = KopPanelView(viewModel: viewModel, preferences: preferences)
        let hosting = NSHostingView(rootView: contentView)

        let panel = KopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
        }

        super.init(window: panel)
        panel.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePanel),
            name: .closeClipboardPanel,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
        window?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if NSApp.keyWindow?.identifier?.rawValue == "preferencesWindow" {
            return
        }
        closePanel()
    }

    private func showPanel() {
        guard let panel = window as? NSPanel else { return }
        position(panel: panel)
        viewModel.reload()

        let finalFrame = panel.frame
        let initialFrame = NSRect(
            x: finalFrame.origin.x + finalFrame.width * 0.025,
            y: finalFrame.origin.y + finalFrame.height * 0.025,
            width: finalFrame.width * 0.95,
            height: finalFrame.height * 0.95
        )

        panel.alphaValue = 0
        panel.setFrame(initialFrame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private func position(panel: NSPanel) {
        let cursorLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursorLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}
