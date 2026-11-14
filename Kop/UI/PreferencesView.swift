import AppKit
import Carbon
import Combine
import SwiftUI

/// Runs blocking work (database cleanups) on a background queue and resumes
/// the caller afterwards, back on its actor.
func runOffMain(_ work: @escaping () -> Void) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            continuation.resume()
        }
    }
}

@MainActor
final class PreferencesViewModel: ObservableObject {
    let preferences: PreferencesStore
    private let persistence: PersistenceManager
    private var cancellables: Set<AnyCancellable> = []

    @Published var storageStats = StorageStats(totalItems: 0, totalSizeBytes: 0, oldestItemDate: nil)
    @Published var accessibilityGranted = AccessibilityPermission.isGranted
    @Published private(set) var isCleaning = false

    init(preferences: PreferencesStore, persistence: PersistenceManager = .shared) {
        self.preferences = preferences
        self.persistence = persistence

        // Re-publish the store's changes so the form redraws.
        preferences.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refresh() {
        storageStats = persistence.fetchStorageStats()
        accessibilityGranted = AccessibilityPermission.isGranted
    }

    func clearItemsOlderThan(days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let persistence = persistence
        runCleanup { persistence.deleteItemsOlderThan(cutoff) }
    }

    func clearAllExceptFavorites() {
        let persistence = persistence
        runCleanup { persistence.clearNonFavoriteItems() }
    }

    /// Cleanups end in a VACUUM that can take seconds, so they run off the
    /// main thread while the buttons are disabled.
    private func runCleanup(_ work: @escaping () -> Void) {
        guard !isCleaning else { return }
        isCleaning = true
        Task {
            await runOffMain(work)
            isCleaning = false
            refresh()
            NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var selectedTab = 0

    private var preferences: PreferencesStore { viewModel.preferences }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("Geral", systemImage: "gearshape") }
                .tag(0)

            captureTab
                .tabItem { Label("Captura", systemImage: "doc.on.clipboard") }
                .tag(1)

            StoragePreferencesTab(
                stats: viewModel.storageStats,
                isCleaning: viewModel.isCleaning,
                clear7Days: {
                    confirmAndRun(title: "Limpar itens com mais de 7 dias?", message: "Favoritos são mantidos.") {
                        viewModel.clearItemsOlderThan(days: 7)
                    }
                },
                clear30Days: {
                    confirmAndRun(title: "Limpar itens com mais de 30 dias?", message: "Favoritos são mantidos.") {
                        viewModel.clearItemsOlderThan(days: 30)
                    }
                },
                clearAll: {
                    confirmAndRun(title: "Limpar tudo?", message: "Todos os itens não favoritados serão removidos.") {
                        viewModel.clearAllExceptFavorites()
                    }
                }
            )
            .tabItem { Label("Armazenamento", systemImage: "internaldrive") }
            .tag(2)
        }
        .frame(width: 460, height: 400)
        .background(PreferencesWindowConfigurator())
    }

    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Atalho global")
                    Spacer()
                    HotkeyRecorderView(shortcut: Binding(
                        get: { preferences.hotkey },
                        set: { preferences.hotkey = $0 }
                    ))
                    Button("Restaurar") { preferences.hotkey = .default }
                }
                Toggle("Iniciar com o sistema", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { preferences.launchAtLogin = $0 }
                ))
            }

            Section {
                Toggle("Colar automaticamente ao escolher um item", isOn: Binding(
                    get: { preferences.pasteOnSelect },
                    set: { preferences.pasteOnSelect = $0 }
                ))
                if preferences.pasteOnSelect && !viewModel.accessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Requer permissão de Acessibilidade.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Autorizar") {
                            AccessibilityPermission.ensureGranted()
                            viewModel.refresh()
                        }
                        .controlSize(.small)
                    }
                }
            } footer: {
                Text("Sem essa opção, o item é apenas copiado e você cola com ⌘V.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Tema", selection: Binding(
                    get: { preferences.theme },
                    set: { preferences.theme = $0 }
                )) {
                    ForEach(KopTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker("Som ao copiar", selection: Binding(
                    get: { preferences.soundName },
                    set: { preferences.soundName = $0; $0.play() }
                )) {
                    ForEach(KopSound.allCases) { sound in
                        Text(sound.title).tag(sound)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var captureTab: some View {
        Form {
            Section {
                Picker("Limite do histórico", selection: Binding(
                    get: { preferences.historyLimitSelection },
                    set: { preferences.historyLimitSelection = $0 }
                )) {
                    Text("50 itens").tag(50)
                    Text("200 itens").tag(200)
                    Text("500 itens").tag(500)
                    Text("2000 itens").tag(2000)
                    Text("Ilimitado").tag(0)
                }
                Toggle("Capturar imagens", isOn: Binding(
                    get: { preferences.captureImagesEnabled },
                    set: { preferences.captureImagesEnabled = $0 }
                ))
                Toggle("Capturar arquivos", isOn: Binding(
                    get: { preferences.captureFilesEnabled },
                    set: { preferences.captureFilesEnabled = $0 }
                ))
            } footer: {
                Text("Favoritos nunca são removidos pelo limite.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Itens de apps sensíveis", selection: Binding(
                    get: { preferences.sensitiveCaptureBehavior },
                    set: { preferences.sensitiveCaptureBehavior = $0 }
                )) {
                    ForEach(SensitiveCaptureBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            } footer: {
                Text("Conteúdo marcado como confidencial (gerenciadores de senha) é sempre ignorado.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func confirmAndRun(title: String, message: String, action: () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Confirmar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

private struct StoragePreferencesTab: View {
    let stats: StorageStats
    let isCleaning: Bool
    let clear7Days: () -> Void
    let clear30Days: () -> Void
    let clearAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    statRow("Itens no histórico", "\(stats.totalItems)")
                    Divider()
                    statRow("Espaço ocupado", stats.totalSizeBytes.formatted(.byteCount(style: .file).locale(.kop)))
                    Divider()
                    statRow("Item mais antigo", oldestItemText)
                }
                .padding(6)
            }

            GroupBox("Limpeza") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Limpar itens com mais de 7 dias", action: clear7Days)
                    Button("Limpar itens com mais de 30 dias", action: clear30Days)
                    HStack(spacing: 8) {
                        Button("Limpar tudo (exceto favoritos)", action: clearAll)
                        if isCleaning {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isCleaning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Spacer()
        }
        .padding(20)
    }

    private var oldestItemText: String {
        guard let date = stats.oldestItemDate else { return "—" }
        return date.formatted(.dateTime.day().month(.wide).year().locale(.kop))
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Hotkey recorder

private struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotkeyShortcut

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onChange = { shortcut = $0 }
        if !nsView.isRecording {
            nsView.shortcut = shortcut
        }
    }
}

/// Click to record, then press a combination containing Command, Option or
/// Control. Escape cancels.
final class HotkeyRecorderNSView: NSView {
    var onChange: ((HotkeyShortcut) -> Void)?

    var shortcut: HotkeyShortcut = .default {
        didSet { updateLabel() }
    }

    /// The global hotkey is paused while recording, so pressing the current
    /// shortcut records it instead of opening the panel.
    private(set) var isRecording = false {
        didSet {
            updateLabel()
            guard isRecording != oldValue else { return }
            NotificationCenter.default.post(name: .hotkeyRecordingChanged, object: isRecording)
        }
    }

    private var windowObserver: NSObjectProtocol?

    /// Closing or leaving the window must not leave the hotkey paused.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        guard let window else {
            isRecording = false
            return
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.isRecording = false
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 24) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, capture(event) else {
            super.keyDown(with: event)
            return
        }
    }

    private func capture(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Esc cancels
            isRecording = false
            window?.makeFirstResponder(nil)
            return true
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        let candidate = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard candidate.hasModifier else {
            NSSound.beep()
            return true
        }

        shortcut = candidate
        onChange?(candidate)
        isRecording = false
        window?.makeFirstResponder(nil)
        return true
    }

    private func updateLabel() {
        label.stringValue = isRecording ? "Pressione…" : shortcut.displayString
        label.textColor = isRecording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

private struct PreferencesWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier("preferencesWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
