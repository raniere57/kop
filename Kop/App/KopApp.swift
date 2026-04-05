import SwiftUI

@main
struct KopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView(viewModel: appDelegate.preferencesViewModel)
                .frame(width: 420, height: 280)
        }
    }
}
