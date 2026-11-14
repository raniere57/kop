import AppKit
import SwiftUI

struct KopPanelView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        Group {
            if let expanded = viewModel.expandedItem {
                // Replaces the list instead of overlaying it: on macOS the List
                // is an AppKit view and SwiftUI overlays do not composite over
                // it reliably.
                ImageLightboxView(
                    item: expanded,
                    image: viewModel.expandedImage,
                    position: viewModel.expandedPosition,
                    onPrevious: { viewModel.stepExpanded(by: -1) },
                    onNext: { viewModel.stepExpanded(by: 1) },
                    onCopy: { viewModel.copyExpanded(autoPaste: false) },
                    onPaste: { viewModel.copyExpanded(autoPaste: true) },
                    onClose: { viewModel.collapse() }
                )
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.6)
                    content
                    Divider().opacity(0.6)
                    footer
                }
            }
        }
        .background(PanelBackgroundView().ignoresSafeArea())
        // The window drives the size (it grows while an image is expanded), so
        // the content just fills it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(colorScheme)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            SearchBar(text: $viewModel.searchText)

            Picker("", selection: $viewModel.listFilter) {
                ForEach(ClipboardListFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.symbolName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                NotificationCenter.default.post(name: .openPreferencesWindow, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preferências")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(selection: $viewModel.selectedItemID) {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        ClipboardItemRow(
                            item: item,
                            isSelected: viewModel.selectedItemID == item.id,
                            shortcutIndex: index < 9 ? index + 1 : nil,
                            onToggleFavorite: { viewModel.toggleFavorite(item: item) },
                            onExpandImage: { viewModel.expand(item: item) }
                        )
                        .id(item.id)
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedItemID = item.id
                            viewModel.activateSelectedItem()
                        }
                        .contextMenu { contextMenu(for: item) }
                        .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.selectedItemID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.listFilter == .favorites ? "star" : "doc.on.clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(viewModel.emptyStateTitle)
                .font(.system(size: 14, weight: .semibold))
            Text(viewModel.emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardEntry) -> some View {
        Button("Colar") { viewModel.copy(item: item, plainTextOnly: false, autoPaste: true) }
        Button("Copiar") { viewModel.copy(item: item, plainTextOnly: false, autoPaste: false) }
        if item.type == .richText {
            Button("Copiar como texto puro") { viewModel.copy(item: item, plainTextOnly: true, autoPaste: false) }
        }
        Divider()
        if item.type == .image {
            Button("Expandir imagem") { viewModel.expand(item: item) }
        }
        Button("Visualizar em janela") { PreviewWindowController.shared.show(item: item) }
        if let path = item.filePath, item.type == .fileURL || item.type == .image {
            Button("Mostrar no Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button(item.isFavorite ? "Remover favorito" : "Favoritar") { viewModel.toggleFavorite(item: item) }
        Button(item.customTitle == nil ? "Dar título" : "Editar título") { promptForTitle(item) }
        Divider()
        Button("Apagar", role: .destructive) { viewModel.delete(item: item) }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Only loaded rows are counted; "+" says more pages exist.
            Text("\(viewModel.items.count)\(viewModel.hasMore ? "+" : "") \(viewModel.items.count == 1 && !viewModel.hasMore ? "item" : "itens")")
            Spacer(minLength: 0)
            hint("↑↓", "navegar")
            hint("↵", preferences.pasteOnSelect ? "colar" : "copiar")
            hint("⌘D", "favoritar")
            hint("⌘⌫", "apagar")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label)
        }
    }

    private var colorScheme: ColorScheme? {
        switch preferences.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func promptForTitle(_ item: ClipboardEntry) {
        let field = NSTextField(string: item.customTitle ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = "Título do item"
        alert.informativeText = "Dê um nome curto para encontrar este item mais rápido. Deixe vazio para remover o título."
        alert.accessoryView = field
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        viewModel.updateCustomTitle(item: item, title: field.stringValue)
    }
}

private struct PanelBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        view.blendingMode = .behindWindow
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
