import Carbon
import AppKit
import SwiftUI

@MainActor
final class PreferencesViewModel: ObservableObject {
    var preferences: PreferencesStore
    private let persistence: PersistenceManager

    @Published var storageStats = StorageStats(totalItems: 0, totalSizeBytes: 0, oldestItemDate: nil)

    init(preferences: PreferencesStore, persistence: PersistenceManager = .shared) {
        self.preferences = preferences
        self.persistence = persistence
    }

    func reloadStorageStats() {
        storageStats = persistence.fetchStorageStats()
    }

    func clearItemsOlderThan(days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        persistence.deleteItemsOlderThan(cutoff)
        reloadStorageStats()
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
    }

    func clearAllExceptFavorites() {
        persistence.clearNonFavoriteItems()
        reloadStorageStats()
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
    }
}

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Picker("Limite do histórico", selection: $viewModel.preferences.historyLimitSelection) {
                    Text("50").tag(50)
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("Ilimitado").tag(0)
                }
                Toggle("Capturar imagens", isOn: $viewModel.preferences.captureImagesEnabled)
                Toggle("Capturar arquivos", isOn: $viewModel.preferences.captureFilesEnabled)
                Toggle("Iniciar com o sistema", isOn: $viewModel.preferences.launchAtLogin)
                Picker("Tema", selection: $viewModel.preferences.theme) {
                    Text("Automático").tag(KopTheme.system)
                    Text("Claro").tag(KopTheme.light)
                    Text("Escuro").tag(KopTheme.dark)
                }
                Picker("Itens sensíveis", selection: $viewModel.preferences.sensitiveCaptureBehavior) {
                    ForEach(SensitiveCaptureBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                HStack {
                    Text("Atalho global")
                    Spacer()
                    HotkeyRecorderView(shortcut: $viewModel.preferences.hotkey)
                    Button("Restaurar") {
                        viewModel.preferences.hotkey = .default
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem {
                Text("Geral")
            }
            .tag(0)

            StoragePreferencesTab(
                stats: viewModel.storageStats,
                clear7Days: { confirmAndRun(
                    title: "Limpar itens mais antigos que 7 dias?",
                    message: "Itens favoritos serão mantidos."
                ) {
                    viewModel.clearItemsOlderThan(days: 7)
                } },
                clear30Days: { confirmAndRun(
                    title: "Limpar itens mais antigos que 30 dias?",
                    message: "Itens favoritos serão mantidos."
                ) {
                    viewModel.clearItemsOlderThan(days: 30)
                } },
                clearAll: { confirmAndRun(
                    title: "Limpar tudo?",
                    message: "Todos os itens não favoritados serão removidos."
                ) {
                    viewModel.clearAllExceptFavorites()
                } }
            )
            .padding()
            .tabItem {
                Text("Armazenamento")
            }
            .tag(1)
        }
        .onAppear {
            viewModel.reloadStorageStats()
        }
        .background(PreferencesWindowConfigurator())
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
    let clear7Days: () -> Void
    let clear30Days: () -> Void
    let clearAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    statRow(title: "Total de itens copiados", value: "\(stats.totalItems) itens")
                    statRow(title: "Espaço ocupado", value: ByteCountFormatter.string(fromByteCount: stats.totalSizeBytes, countStyle: .file))
                    statRow(title: "Item mais antigo", value: oldestItemText)
                }
            }
            GroupBox("Limpeza") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Limpar itens mais antigos que 7 dias", action: clear7Days)
                    Button("Limpar itens mais antigos que 30 dias", action: clear30Days)
                    Button("Limpar tudo (exceto favoritos)", role: .destructive, action: clearAll)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
    }

    private var oldestItemText: String {
        guard let date = stats.oldestItemDate else { return "Sem itens" }
        return "Desde \(date.formatted(.dateTime.day().month(.wide).year()))"
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotkeyShortcut

    func makeNSView(context: Context) -> HotkeyRecorderTextField {
        let field = HotkeyRecorderTextField()
        field.placeholderString = "Pressione um atalho"
        field.alignment = .center
        field.delegate = context.coordinator
        field.stringValue = shortcut.displayString
        return field
    }

    func updateNSView(_ nsView: HotkeyRecorderTextField, context: Context) {
        nsView.stringValue = shortcut.displayString
        context.coordinator.shortcut = $shortcut
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var shortcut: Binding<HotkeyShortcut>

        init(shortcut: Binding<HotkeyShortcut>) {
            self.shortcut = shortcut
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? HotkeyRecorderTextField else { return }
            field.stringValue = "Aguardando..."
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            false
        }
    }
}

private final class HotkeyRecorderTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option) else {
            return false
        }
        let modifiers = carbonModifiers(from: event.modifierFlags)
        let updated = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)

        if let delegate = delegate as? HotkeyRecorderView.Coordinator {
            delegate.shortcut.wrappedValue = updated
        }

        stringValue = updated.displayString
        abortEditing()
        window?.makeFirstResponder(nil)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        stringValue = "Aguardando..."
        return super.becomeFirstResponder()
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

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.identifier = NSUserInterfaceItemIdentifier("preferencesWindow")
        }
    }
}
