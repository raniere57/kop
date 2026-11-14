import AppKit

/// Resolving an app icon hits LaunchServices, which is far too slow to do on
/// every row redraw — results are memoised per source app.
enum AppIconFetcher {
    private static var cache: [String: NSImage] = [:]
    private static let fallback = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)

    static func icon(for bundleIdentifier: String?, appName: String?) -> NSImage? {
        let key = bundleIdentifier ?? appName ?? ""
        guard !key.isEmpty else { return fallback }
        if let cached = cache[key] { return cached }

        let resolved = resolve(bundleIdentifier: bundleIdentifier, appName: appName) ?? fallback
        if let resolved { cache[key] = resolved }
        return resolved
    }

    private static func resolve(bundleIdentifier: String?, appName: String?) -> NSImage? {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let appName,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
           let url = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
