import AppKit
import SwiftUI

@MainActor
final class PreferencesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel

    init(viewModel: PreferencesViewModel) {
        self.viewModel = viewModel
        let rootView = PreferencesView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)
        let window = PreferencesWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("preferencesWindow")
        window.title = "Preferências"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 400))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak viewModel] _ in
            MainActor.assumeIsolated { viewModel?.isWindowVisible = false }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        // The window is reused, so stats must be re-read on every show.
        viewModel.isWindowVisible = true
        viewModel.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
