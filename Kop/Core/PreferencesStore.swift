import AppKit
import ServiceManagement

enum SensitiveCaptureBehavior: String, CaseIterable, Identifiable {
    case ask
    case save
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Perguntar"
        case .save: return "Salvar"
        case .ignore: return "Ignorar"
        }
    }
}

enum KopTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published var historyLimitSelection: Int = 500 { didSet { defaults.set(historyLimitSelection, forKey: Keys.historyLimit) } }
    @Published var captureImagesEnabled: Bool = true { didSet { defaults.set(captureImagesEnabled, forKey: Keys.captureImages) } }
    @Published var captureFilesEnabled: Bool = true { didSet { defaults.set(captureFilesEnabled, forKey: Keys.captureFiles) } }
    @Published var hotkey: HotkeyShortcut = .default {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Keys.hotkeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Keys.hotkeyModifiers)
            NotificationCenter.default.post(name: .preferencesHotkeyChanged, object: nil)
        }
    }
    @Published var launchAtLogin: Bool = false { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin); updateLaunchAtLogin() } }
    @Published var theme: KopTheme = .system { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    @Published var sensitiveCaptureBehavior: SensitiveCaptureBehavior = .ask { didSet { defaults.set(sensitiveCaptureBehavior.rawValue, forKey: Keys.sensitiveCaptureBehavior) } }

    private let defaults = UserDefaults.standard

    var historyLimit: Int? {
        historyLimitSelection == 0 ? nil : historyLimitSelection
    }

    private enum Keys {
        static let historyLimit = "historyLimit"
        static let captureImages = "captureImages"
        static let captureFiles = "captureFiles"
        static let hotkeyCode = "hotkeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let launchAtLogin = "launchAtLogin"
        static let theme = "theme"
        static let sensitiveCaptureBehavior = "sensitiveCaptureBehavior"
    }

    private init() {
        historyLimitSelection = defaults.object(forKey: Keys.historyLimit) as? Int ?? 500
        captureImagesEnabled = defaults.object(forKey: Keys.captureImages) as? Bool ?? true
        captureFilesEnabled = defaults.object(forKey: Keys.captureFiles) as? Bool ?? true
        let keyCode = defaults.object(forKey: Keys.hotkeyCode) as? Int ?? Int(HotkeyShortcut.default.keyCode)
        let modifiers = defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Int(HotkeyShortcut.default.modifiers)
        hotkey = HotkeyShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        theme = KopTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        sensitiveCaptureBehavior = SensitiveCaptureBehavior(rawValue: defaults.string(forKey: Keys.sensitiveCaptureBehavior) ?? "") ?? .ask
    }

    private func updateLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Failed to update launch at login: \(error.localizedDescription)")
        }
    }
}
