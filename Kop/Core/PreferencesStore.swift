import AppKit
import Carbon
import ServiceManagement

public struct HotkeyShortcut: Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey)
    )

    public var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    /// True when at least one modifier is set. Registering a bare key would
    /// swallow it system-wide, so the recorder rejects those.
    public var hasModifier: Bool { modifiers != 0 }

    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
        kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Del",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`"
    ]

    static func keyName(for keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "Key \(keyCode)"
    }
}

public enum SensitiveCaptureBehavior: String, CaseIterable, Identifiable {
    case ask
    case save
    case ignore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return "Perguntar"
        case .save: return "Salvar"
        case .ignore: return "Ignorar"
        }
    }
}

public enum KopTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Automático"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }

    public var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .vibrantLight)
        case .dark: return NSAppearance(named: .vibrantDark)
        }
    }
}

public enum KopSound: String, CaseIterable, Identifiable {
    case none = ""
    case purr = "Purr"
    case pop = "Pop"
    case glass = "Glass"
    case sosumi = "Sosumi"
    case submarine = "Submarine"

    public var id: String { rawValue }

    public var title: String { self == .none ? "Nenhum" : rawValue }

    public func play() {
        guard self != .none else { return }
        NSSound(named: rawValue)?.play()
    }
}

/// Preferences are read from the clipboard monitor's background queue, so the
/// stored values are mirrored into a lock-protected snapshot.
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    struct Snapshot {
        var historyLimit: Int?
        var captureImagesEnabled: Bool
        var captureFilesEnabled: Bool
        var sensitiveCaptureBehavior: SensitiveCaptureBehavior
        var sound: KopSound
    }

    @Published var historyLimitSelection = 500 { didSet { persist(historyLimitSelection, Keys.historyLimit) } }
    @Published var captureImagesEnabled = true { didSet { persist(captureImagesEnabled, Keys.captureImages) } }
    @Published var captureFilesEnabled = true { didSet { persist(captureFilesEnabled, Keys.captureFiles) } }
    @Published var pasteOnSelect = true { didSet { persist(pasteOnSelect, Keys.pasteOnSelect) } }
    @Published var hotkey: HotkeyShortcut = .default {
        didSet {
            guard hotkey != oldValue else { return }
            defaults.set(Int(hotkey.keyCode), forKey: Keys.hotkeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Keys.hotkeyModifiers)
            NotificationCenter.default.post(name: .preferencesHotkeyChanged, object: nil)
        }
    }
    @Published var launchAtLogin = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            persist(launchAtLogin, Keys.launchAtLogin)
            updateLaunchAtLogin()
        }
    }
    @Published var theme: KopTheme = .system {
        didSet {
            guard theme != oldValue else { return }
            persist(theme.rawValue, Keys.theme)
            NotificationCenter.default.post(name: .preferencesThemeChanged, object: nil)
        }
    }
    @Published var sensitiveCaptureBehavior: SensitiveCaptureBehavior = .ask { didSet { persist(sensitiveCaptureBehavior.rawValue, Keys.sensitiveCaptureBehavior) } }
    @Published var soundName: KopSound = .purr { didSet { persist(soundName.rawValue, Keys.soundName) } }

    private let defaults = UserDefaults.standard
    private let snapshotLock = NSLock()
    private var _snapshot: Snapshot

    /// Thread-safe view of the values the background monitor needs.
    var snapshot: Snapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return _snapshot
    }

    private enum Keys {
        static let historyLimit = "historyLimit"
        static let captureImages = "captureImages"
        static let captureFiles = "captureFiles"
        static let pasteOnSelect = "pasteOnSelect"
        static let hotkeyCode = "hotkeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let launchAtLogin = "launchAtLogin"
        static let theme = "theme"
        static let sensitiveCaptureBehavior = "sensitiveCaptureBehavior"
        static let soundName = "soundName"
    }

    private init() {
        let storedLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 500
        let images = defaults.object(forKey: Keys.captureImages) as? Bool ?? true
        let files = defaults.object(forKey: Keys.captureFiles) as? Bool ?? true
        let behavior = SensitiveCaptureBehavior(rawValue: defaults.string(forKey: Keys.sensitiveCaptureBehavior) ?? "") ?? .ask
        let sound = KopSound(rawValue: defaults.string(forKey: Keys.soundName) ?? "Purr") ?? .purr

        _snapshot = Snapshot(
            historyLimit: storedLimit == 0 ? nil : storedLimit,
            captureImagesEnabled: images,
            captureFilesEnabled: files,
            sensitiveCaptureBehavior: behavior,
            sound: sound
        )

        historyLimitSelection = storedLimit
        captureImagesEnabled = images
        captureFilesEnabled = files
        pasteOnSelect = defaults.object(forKey: Keys.pasteOnSelect) as? Bool ?? true
        let keyCode = defaults.object(forKey: Keys.hotkeyCode) as? Int ?? Int(HotkeyShortcut.default.keyCode)
        let modifiers = defaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? Int(HotkeyShortcut.default.modifiers)
        hotkey = HotkeyShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        theme = KopTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        sensitiveCaptureBehavior = behavior
        soundName = sound
    }

    var historyLimit: Int? {
        historyLimitSelection == 0 ? nil : historyLimitSelection
    }

    private func persist(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        snapshotLock.lock()
        _snapshot = Snapshot(
            historyLimit: historyLimit,
            captureImagesEnabled: captureImagesEnabled,
            captureFilesEnabled: captureFilesEnabled,
            sensitiveCaptureBehavior: sensitiveCaptureBehavior,
            sound: soundName
        )
        snapshotLock.unlock()
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[Kop] Falha ao atualizar 'iniciar com o sistema': \(error.localizedDescription)")
        }
    }
}
