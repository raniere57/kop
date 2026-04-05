import AppKit
import Combine
import SwiftUI

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardEntry] = []
    @Published var searchText = ""
    @Published var selectedItemID: Int64?

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
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)

        reload()
    }

    func reload() {
        currentOffset = 0
        let freshItems = persistence.fetchItems(offset: 0, limit: pageSize, searchTerm: searchText)
        items = freshItems
        selectedItemID = freshItems.first?.id
        hasMore = freshItems.count == pageSize
    }

    func loadMoreIfNeeded(currentItem: ClipboardEntry) {
        guard hasMore, currentItem.id == items.last?.id else { return }
        currentOffset += pageSize
        let nextPage = persistence.fetchItems(offset: currentOffset, limit: pageSize, searchTerm: searchText)
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
        NotificationCenter.default.post(name: .closeClipboardPanel, object: nil)
    }

    func copy(item: ClipboardEntry, plainTextOnly: Bool, autoPaste: Bool) {
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
            PasteSimulator.simulatePaste()
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

    var selectedItem: ClipboardEntry? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID })
    }
}
