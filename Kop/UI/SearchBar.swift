import AppKit
import SwiftUI

struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(text: $text)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Limpar busca")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }
}

private struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> EscapableSearchTextField {
        let field = EscapableSearchTextField()
        field.identifier = SearchFieldIdentifier
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Buscar no histórico…"
        field.delegate = context.coordinator
        field.stringValue = text
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ nsView: EscapableSearchTextField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

let SearchFieldIdentifier = NSUserInterfaceItemIdentifier("kopSearchField")

private final class EscapableSearchTextField: NSTextField {
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
    }
}

extension NSView {
    /// Depth-first lookup used to restore focus to the search field whenever
    /// the panel is shown again.
    func firstDescendant(matching identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        if self.identifier == identifier { return self }
        for subview in subviews {
            if let match = subview.firstDescendant(matching: identifier) { return match }
        }
        return nil
    }
}
