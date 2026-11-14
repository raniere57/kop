import Foundation

extension NSNotification.Name {
    static let clipboardHistoryChanged = NSNotification.Name("clipboardHistoryChanged")
    static let preferencesHotkeyChanged = NSNotification.Name("preferencesHotkeyChanged")
    static let preferencesThemeChanged = NSNotification.Name("preferencesThemeChanged")
    static let closeClipboardPanel = NSNotification.Name("closeClipboardPanel")
    static let openPreferencesWindow = NSNotification.Name("openPreferencesWindow")
}
