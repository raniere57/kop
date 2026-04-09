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
}

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardEntry] = []
    @Published var searchText = ""
    @Published var selectedItemID: Int64?
    @Published var listFilter: ClipboardListFilter = .all

    private let persistence: PersistenceManager
    private let preferences: PreferencesStore
    private let clipboardMonitor: ClipboardMonitor
    private var cancellables: Set<AnyCancellable> = []
    private let pageSize = 50
    private var currentOffset = 0
    private var hasMore = true

    init(persistence: PersistenceManager, preferences: PreferencesStore, clipboardMonitor: ClipboardMonitor) {
        self.persistence = persistence
        self.preferences = preferences
        self.clipboardMonitor = clipboardMonitor

        NotificationCenter.default.publisher(for: .clipboardHistoryChanged)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)

        $searchText
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] searchText in
                self?.reload(searchTerm: searchText)
            }
            .store(in: &cancellables)

        $listFilter
            .removeDuplicates()
            .sink { [weak self] listFilter in
                self?.reload(filter: listFilter)
            }
            .store(in: &cancellables)

        reload()
    }

    func reload(searchTerm: String? = nil, filter: ClipboardListFilter? = nil) {
        currentOffset = 0
        let freshItems = fetchPage(
            offset: 0,
            searchTerm: searchTerm ?? self.searchText,
            filter: filter ?? self.listFilter
        )
        items = freshItems
        selectedItemID = freshItems.first?.id
        hasMore = freshItems.count == pageSize
    }

    func loadMoreIfNeeded(currentItem: ClipboardEntry) {
        guard hasMore, currentItem.id == items.last?.id else { return }
        currentOffset += pageSize
        let nextPage = fetchPage(
            offset: currentOffset,
            searchTerm: searchText,
            filter: listFilter
        )
        hasMore = nextPage.count == pageSize
        items.append(contentsOf: nextPage)
    }

    func selectNext() {
        guard !items.isEmpty else { return }
        guard let selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = items.first?.id
            return
        }
        self.selectedItemID = items[min(currentIndex + 1, items.count - 1)].id
    }

    func selectPrevious() {
        guard !items.isEmpty else { return }
        guard let selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = items.first?.id
            return
        }
        self.selectedItemID = items[max(currentIndex - 1, 0)].id
    }

    func activateSelectedItem() {
        guard let selected = selectedItem else { return }
        copy(item: selected, plainTextOnly: false, autoPaste: false)
    }

    func copy(item: ClipboardEntry, plainTextOnly: Bool, autoPaste: Bool) {
        NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)

        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            switch item.type {
            case .plainText, .fileURL, .pdf:
                if let text = item.textContent ?? item.filePath {
                    pasteboard.setString(text, forType: .string)
                } else if let data = item.binaryData {
                    pasteboard.setData(data, forType: .pdf)
                }
            case .richText:
                if plainTextOnly {
                    pasteboard.setString(item.textContent ?? "", forType: .string)
                } else if let richTextData = item.richTextData {
                    pasteboard.setData(richTextData, forType: .rtf)
                    if let textContent = item.textContent {
                        pasteboard.setString(textContent, forType: .string)
                    }
                }
            case .image:
                if let data = item.binaryData {
                    pasteboard.setData(data, forType: .png)
                } else if let thumbnailPath = item.thumbnailPath,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: thumbnailPath)) {
                    pasteboard.setData(data, forType: .png)
                }
            }

            if autoPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    PasteSimulator.simulatePaste()
                }
            }
        }
    }

    func delete(item: ClipboardEntry) {
        persistence.delete(id: item.id)
        reload()
    }

    func toggleFavorite(item: ClipboardEntry) {
        persistence.setFavorite(id: item.id, isFavorite: !item.isFavorite)
        reload()
    }

    func updateCustomTitle(item: ClipboardEntry, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        persistence.setCustomTitle(id: item.id, title: trimmed.isEmpty ? nil : trimmed)
        reload()
    }

    var selectedItem: ClipboardEntry? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID })
    }

    var emptyStateTitle: String {
        if listFilter == .favorites {
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Nenhum favorito salvo"
                : "Nenhum favorito encontrado"
        }
        return "Nenhum item encontrado"
    }

    var emptyStateMessage: String {
        if listFilter == .favorites {
            return "Favorite itens importantes para encontrá-los mais rápido."
        }
        return "Tente ajustar a busca para encontrar uma cópia anterior."
    }

    private func fetchPage(offset: Int, searchTerm: String, filter: ClipboardListFilter) -> [ClipboardEntry] {
        if filter == .favorites {
            let scanLimit = max(preferences.historyLimit ?? 5_000, pageSize)
            let allItems = persistence.fetchItems(
                offset: 0,
                limit: scanLimit,
                searchTerm: searchTerm,
                favoritesOnly: false
            )
            let favorites = allItems.filter(\.isFavorite)
            guard offset < favorites.count else { return [] }
            let endIndex = min(offset + pageSize, favorites.count)
            return Array(favorites[offset..<endIndex])
        }

        return persistence.fetchItems(
            offset: offset,
            limit: pageSize,
            searchTerm: searchTerm,
            favoritesOnly: false
        )
    }
}
