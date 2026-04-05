import Carbon
import SwiftUI

@MainActor
final class PreferencesViewModel: ObservableObject {
    var preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }
}

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
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
