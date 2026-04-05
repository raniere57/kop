import AppKit

enum AppIconFetcher {
    static func icon(for bundleIdentifier: String?, appName: String?) -> NSImage? {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        if let appName {
            let apps = NSWorkspace.shared.runningApplications
            if let app = apps.first(where: { $0.localizedName == appName }),
               let url = app.bundleURL {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }
}
