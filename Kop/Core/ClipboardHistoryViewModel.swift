import AppKit
import Combine
import SwiftUI

enum ClipboardListFilter: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tudo"
        case .favorites: return "Favoritos"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "clock"
        case .favorites: return "star.fill"
        }
    }
}

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardEntry] = []
    @Published var searchText = ""
    @Published var selectedItemID: Int64?
    @Published var listFilter: ClipboardListFilter = .all
    /// Non-nil while an image is shown expanded over the list.
    @Published private(set) var expandedItem: ClipboardEntry?
    /// Decoded together with `expandedItem` (same update), so the lightbox
    /// never renders a frame without an image. Released on collapse.
    @Published private(set) var expandedImage: NSImage?
    /// True while the store is rebuilding or compacting; the list shows a
    /// notice instead of blocking the main thread on the database.
    @Published private(set) var isStorageBusy = false

    private let persistence: PersistenceManager
    private let preferences: PreferencesStore
    private let clipboardMonitor: ClipboardMonitor
    private var cancellables: Set<AnyCancellable> = []
    private let pageSize = 50
    private(set) var hasMore = true
    /// Set by the panel controller. Reloads are skipped while the panel is
    /// hidden; showing it reloads anyway.
    var isPanelVisible = false
    /// App that was frontmost when the panel opened; auto-paste goes back to it.
    var pasteTargetApp: NSRunningApplication?

    init(persistence: PersistenceManager, preferences: PreferencesStore, clipboardMonitor: ClipboardMonitor) {
        self.persistence = persistence
        self.preferences = preferences
        self.clipboardMonitor = clipboardMonitor

        NotificationCenter.default.publisher(for: .clipboardHistoryChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isPanelVisible else { return }
                self.reload()
            }
            .store(in: &cancellables)

        // `dropFirst` + `removeDuplicates` keep the panel from issuing three
        // identical queries every time it opens.
        $searchText
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] searchText in
                guard let self, self.isPanelVisible else { return }
                self.reload(searchTerm: searchText)
            }
            .store(in: &cancellables)

        $listFilter
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] listFilter in
                guard let self, self.isPanelVisible else { return }
                self.reload(filter: listFilter)
            }
            .store(in: &cancellables)
        // No initial load: the panel reloads every time it is shown.
    }

    // MARK: - Loading

    /// Opening the panel always starts fresh: first page, first row.
    func reloadForShow() {
        selectedItemID = nil
        reload(fromTop: true)
    }

    /// A new search, filter or panel open starts from the first page; any
    /// other reload (capture, favorite, rename, delete while visible)
    /// refetches everything already loaded so the user keeps their place.
    func reload(searchTerm: String? = nil, filter: ClipboardListFilter? = nil, fromTop: Bool = false) {
        isStorageBusy = persistence.isBusy
        guard !isStorageBusy else {
            items = []
            hasMore = false
            selectedItemID = nil
            return
        }
        let isNewQuery = fromTop || searchTerm != nil || filter != nil
        let limit = isNewQuery ? pageSize : max(items.count, pageSize)
        let freshItems = fetchPage(
            offset: 0,
            limit: limit,
            searchTerm: searchTerm ?? searchText,
            filter: filter ?? listFilter
        )
        let previousSelection = selectedItemID
        items = freshItems
        hasMore = freshItems.count == limit
        // Keep the user's place: a new clipboard capture must not yank the
        // selection back to the top while they are navigating.
        if let previousSelection, freshItems.contains(where: { $0.id == previousSelection }) {
            selectedItemID = previousSelection
        } else {
            selectedItemID = freshItems.first?.id
        }
    }

    func loadMoreIfNeeded(currentItem: ClipboardEntry) {
        guard hasMore, currentItem.id == items.last?.id, !persistence.isBusy else { return }
        let nextPage = fetchPage(offset: items.count, limit: pageSize, searchTerm: searchText, filter: listFilter)
        hasMore = nextPage.count == pageSize
        items.append(contentsOf: nextPage)
    }

    // MARK: - Selection

    func selectNext() {
        move(by: 1)
    }

    func selectPrevious() {
        move(by: -1)
    }

    func selectFirst() {
        selectedItemID = items.first?.id
    }

    func selectLast() {
        selectedItemID = items.last?.id
    }

    /// Used by ⌘1…⌘9.
    func activateItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedItemID = items[index].id
        activateSelectedItem()
    }

    private func move(by offset: Int) {
        guard !items.isEmpty else { return }
        guard let selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = items.first?.id
            return
        }
        let target = min(max(currentIndex + offset, 0), items.count - 1)
        self.selectedItemID = items[target].id
        if let last = items.last, target >= items.count - 3 {
            loadMoreIfNeeded(currentItem: last)
        }
    }

    var selectedItem: ClipboardEntry? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID })
    }

    // MARK: - Actions

    func activateSelectedItem(plainTextOnly: Bool = false) {
        guard let selected = selectedItem else { return }
        copy(item: selected, plainTextOnly: plainTextOnly, autoPaste: preferences.pasteOnSelect)
    }

    func copy(item: ClipboardEntry, plainTextOnly: Bool, autoPaste: Bool) {
        // List rows are truncated previews: without the full row, write
        // nothing rather than cut text.
        guard let resolved = resolvedItemForCopy(item) else {
            NSSound.beep()
            collapse()
            reload()
            return
        }
        NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
        write(resolved, plainTextOnly: plainTextOnly)
        // Kop wrote the pasteboard itself, so tell the monitor to skip this
        // change and promote the row directly instead of re-capturing it.
        clipboardMonitor.acknowledgeCurrentPasteboardState()
        persistence.touch(id: resolved.id)
        // The monitor skips Kop's own write, so the feedback sound is played here.
        preferences.soundName.play()

        guard autoPaste else { return }
        guard AccessibilityPermission.ensureGranted() else { return }
        // If Kop itself became active (alert, preview, preferences), ⌘V would
        // land in Kop: hand focus back to the app the panel was opened over.
        pasteTargetApp?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteSimulator.simulatePaste()
        }
    }

    private func write(_ item: ClipboardEntry, plainTextOnly: Bool) {
        let pasteboard = NSPasteboard.general

        switch item.type {
        case .plainText:
            pasteboard.clearContents()
            pasteboard.setString(item.textContent ?? "", forType: .string)

        case .fileURL:
            pasteboard.clearContents()
            if let path = item.filePath {
                // Writing the URL object is what makes Finder/Mail accept the paste.
                pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
                pasteboard.setString(path, forType: .string)
            } else {
                pasteboard.setString(item.textContent ?? "", forType: .string)
            }

        case .pdf:
            pasteboard.clearContents()
            if let data = item.binaryData {
                pasteboard.setData(data, forType: .pdf)
            } else if let path = item.filePath {
                pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
            }

        case .richText:
            pasteboard.clearContents()
            if plainTextOnly {
                pasteboard.setString(item.textContent ?? "", forType: .string)
            } else if let richTextData = item.richTextData {
                // HTML captures share this column; only real RTF may be
                // published as RTF.
                let isRTF = NSAttributedString(rtf: richTextData, documentAttributes: nil) != nil
                pasteboard.setData(richTextData, forType: isRTF ? .rtf : .html)
                if let textContent = item.textContent {
                    pasteboard.setString(textContent, forType: .string)
                }
            } else {
                pasteboard.setString(item.textContent ?? "", forType: .string)
            }

        case .image:
            if let payload = ClipboardImageBridge.preparePayload(
                imageData: item.binaryData,
                preferredFilePath: item.filePath,
                fallbackThumbnailPath: item.thumbnailPath
            ) {
                ClipboardImageBridge.publish(payload, to: pasteboard)
            }
        }
    }

    func delete(item: ClipboardEntry) {
        let wasSelected = selectedItemID == item.id
        let nextID = wasSelected ? neighborID(of: item.id) : selectedItemID
        persistence.delete(id: item.id)
        selectedItemID = nextID
        reload()
    }

    func deleteSelected() {
        guard let selectedItem else { return }
        delete(item: selectedItem)
    }

    func toggleFavorite(item: ClipboardEntry) {
        persistence.setFavorite(id: item.id, isFavorite: !item.isFavorite)
        reload()
    }

    func toggleFavoriteSelected() {
        guard let selectedItem else { return }
        toggleFavorite(item: selectedItem)
    }

    func updateCustomTitle(item: ClipboardEntry, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        persistence.setCustomTitle(id: item.id, title: trimmed.isEmpty ? nil : trimmed)
        reload()
    }

    func previewSelected() {
        guard let selectedItem else { return }
        PreviewWindowController.shared.show(item: selectedItem)
    }

    // MARK: - Expanded image

    var imageItems: [ClipboardEntry] {
        items.filter { $0.type == .image }
    }

    /// Position of the expanded image among the images currently listed.
    var expandedPosition: (index: Int, total: Int)? {
        guard let expandedItem else { return nil }
        let images = imageItems
        guard let index = images.firstIndex(where: { $0.id == expandedItem.id }) else { return nil }
        return (index + 1, images.count)
    }

    func expand(item: ClipboardEntry) {
        guard item.type == .image else { return }
        selectedItemID = item.id
        showExpanded(item)
    }

    func collapse() {
        expandedItem = nil
        expandedImage = nil
    }

    private func showExpanded(_ item: ClipboardEntry) {
        let full = withPayload(item)
        expandedImage = ImageThumbnail.shared.originalOrThumbnail(for: full)
        expandedItem = full
    }

    /// Moves through the image items only — stepping onto a text entry would
    /// leave nothing to show.
    func stepExpanded(by offset: Int) {
        guard let expandedItem else { return }
        let images = imageItems
        guard let current = images.firstIndex(where: { $0.id == expandedItem.id }) else { return }
        let target = current + offset
        guard images.indices.contains(target) else { return }
        let next = images[target]
        selectedItemID = next.id
        showExpanded(next)
        // Keep paging so the expanded view can reach older images.
        if let last = items.last, target >= images.count - 2 {
            loadMoreIfNeeded(currentItem: last)
        }
    }

    func copyExpanded(autoPaste: Bool) {
        guard let expandedItem else { return }
        copy(item: expandedItem, plainTextOnly: false, autoPaste: autoPaste)
    }

    /// List rows come without blobs, so the full-size image has to be read
    /// back from the database — a thumbnail path is not enough here.
    private func withPayload(_ item: ClipboardEntry) -> ClipboardEntry {
        if item.binaryData != nil { return item }
        if let path = item.filePath, FileManager.default.fileExists(atPath: path) { return item }
        return persistence.fetchItem(id: item.id) ?? item
    }

    // MARK: - Empty state

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var emptyStateTitle: String {
        if isStorageBusy { return "Otimizando o histórico…" }
        if listFilter == .favorites {
            return isSearching ? "Nenhum favorito encontrado" : "Nenhum favorito salvo"
        }
        return isSearching ? "Nada encontrado" : "Histórico vazio"
    }

    var emptyStateMessage: String {
        if isStorageBusy { return "Leva alguns segundos. A lista volta sozinha quando terminar." }
        if listFilter == .favorites {
            return "Favorite itens importantes para encontrá-los mais rápido."
        }
        return isSearching
            ? "Tente outro termo de busca."
            : "Copie algo em qualquer app e o item aparece aqui."
    }

    // MARK: - Helpers

    private func neighborID(of id: Int64) -> Int64? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if items.indices.contains(index + 1) { return items[index + 1].id }
        if items.indices.contains(index - 1) { return items[index - 1].id }
        return nil
    }

    private func fetchPage(offset: Int, limit: Int, searchTerm: String, filter: ClipboardListFilter) -> [ClipboardEntry] {
        persistence.fetchItems(
            offset: offset,
            limit: limit,
            searchTerm: searchTerm,
            favoritesOnly: filter == .favorites,
            includePayload: false
        )
    }

    /// List rows carry no blobs and only a truncated text preview, so every
    /// type is re-read in full before it reaches the pasteboard.
    /// Nil when the row is gone or unreadable.
    private func resolvedItemForCopy(_ item: ClipboardEntry) -> ClipboardEntry? {
        guard !persistence.isBusy else { return nil }
        return persistence.fetchItem(id: item.id)
    }
}
