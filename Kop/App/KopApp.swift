import SwiftUI

@main
struct KopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Kop is a menu bar app: every window is managed by AppDelegate, so the
    // Settings scene stays empty to avoid a second preferences window.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
