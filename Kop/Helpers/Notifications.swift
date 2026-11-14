import Foundation

extension NSNotification.Name {
    static let clipboardHistoryChanged = NSNotification.Name("clipboardHistoryChanged")
    static let preferencesHotkeyChanged = NSNotification.Name("preferencesHotkeyChanged")
    static let preferencesThemeChanged = NSNotification.Name("preferencesThemeChanged")
    static let closeClipboardPanel = NSNotification.Name("closeClipboardPanel")
    static let openPreferencesWindow = NSNotification.Name("openPreferencesWindow")
    /// `object` is a Bool: true while the hotkey recorder waits for a key.
    static let hotkeyRecordingChanged = NSNotification.Name("hotkeyRecordingChanged")
}
