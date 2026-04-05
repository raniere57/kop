import AppKit
import QuickLook
import SwiftUI

struct KopPanelView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @ObservedObject var preferences: PreferencesStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchBar(text: $viewModel.searchText)
                    .focused($searchFocused)
                Button {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            List(selection: $viewModel.selectedItemID) {
                ForEach(viewModel.items) { item in
                    ClipboardItemRow(item: item, isSelected: viewModel.selectedItemID == item.id)
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Copiar") {
                                viewModel.copy(item: item, plainTextOnly: false, autoPaste: false)
                                NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
                            }
                            if item.type == .richText {
                                Button("Copiar como texto puro") {
                                    viewModel.copy(item: item, plainTextOnly: true, autoPaste: false)
                                    NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
                                }
                            }
                            if item.type == .fileURL, let path = item.filePath {
                                Button("Abrir arquivo") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                }
                            }
                            Button("Visualizar") {
                                PreviewWindowController.shared.show(item: item)
                            }
                            Button(item.isFavorite ? "Remover favorito" : "Favoritar") {
                                viewModel.toggleFavorite(item: item)
                            }
                            Button("Deletar", role: .destructive) {
                                viewModel.delete(item: item)
                            }
                            Button("Copiar e Colar") {
                                viewModel.copy(item: item, plainTextOnly: false, autoPaste: true)
                                NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
                            }
                        }
                        .onTapGesture(count: 2) {
                            PreviewWindowController.shared.show(item: item)
                        }
                        .onTapGesture {
                            viewModel.selectedItemID = item.id
                            viewModel.copy(item: item, plainTextOnly: false, autoPaste: false)
                            NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
                        }
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                        .help(item.previewText)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .background(PanelBackgroundView().ignoresSafeArea())
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 520, minHeight: 400, idealHeight: 520)
        .preferredColorScheme(colorScheme)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        .background(
            KeyHandlingView(
                onEscape: { NotificationCenter.default.post(name: .closeClipboardPanel, object: nil) },
                onUpArrow: { viewModel.selectPrevious() },
                onDownArrow: { viewModel.selectNext() },
                onReturn: { viewModel.activateSelectedItem() }
            )
        )
    }

    private var colorScheme: ColorScheme? {
        switch preferences.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct PanelBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.blendingMode = .behindWindow
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        view.shadow = NSShadow()
        view.shadow?.shadowBlurRadius = 20
        view.shadow?.shadowOffset = .zero
        view.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct KeyHandlingView: NSViewRepresentable {
    let onEscape: () -> Void
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> KeyHandlingNSView {
        let view = KeyHandlingNSView()
        view.onEscape = onEscape
        view.onUpArrow = onUpArrow
        view.onDownArrow = onDownArrow
        view.onReturn = onReturn
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyHandlingNSView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onUpArrow = onUpArrow
        nsView.onDownArrow = onDownArrow
        nsView.onReturn = onReturn
    }
}

final class KeyHandlingNSView: NSView {
    var onEscape: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onReturn: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:
            onEscape?()
        case 125:
            onDownArrow?()
        case 126:
            onUpArrow?()
        case 36:
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}
