// Self-check for Kop's storage layer — the logic most likely to break silently.
// Run: ./Scripts/selfcheck.sh
import Foundation

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok  \(message)")
    } else {
        print("  FAIL \(message)")
        exit(1)
    }
}

private func capture(
    _ text: String,
    type: ClipboardItemType = .plainText,
    favorite: Bool = false,
    createdAt: Date = Date(),
    filePath: String? = nil,
    thumbnailPath: String? = nil
) -> ClipboardCapture {
    ClipboardCapture(
        type: type,
        textContent: text,
        richTextData: nil,
        binaryData: nil,
        filePath: filePath,
        thumbnailPath: thumbnailPath,
        sourceAppName: "TestApp",
        sourceBundleIdentifier: "com.test.app",
        fingerprint: kopDigest(Data(text.utf8)),
        createdAt: createdAt
    )
}

let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("kop-selfcheck-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: sandbox) }

let db = PersistenceManager(directory: sandbox)

print("dedupe")
db.save(capture("alpha"), historyLimit: nil)
db.save(capture("beta"), historyLimit: nil)
db.save(capture("alpha", createdAt: Date().addingTimeInterval(10)), historyLimit: nil)
var items = db.fetchItems(offset: 0, limit: 50, searchTerm: nil, favoritesOnly: false)
check(items.count == 2, "re-copying an older item does not duplicate it")
check(items.first?.textContent == "alpha", "re-copying promotes the item to the top")

print("search")
db.save(capture("100% cotton"), historyLimit: nil)
check(db.fetchItems(offset: 0, limit: 50, searchTerm: "cotton", favoritesOnly: false).count == 1, "plain term matches")
check(db.fetchItems(offset: 0, limit: 50, searchTerm: "100%", favoritesOnly: false).count == 1, "literal % matches its own row")
check(db.fetchItems(offset: 0, limit: 50, searchTerm: "%", favoritesOnly: false).count == 1, "wildcard is escaped, not expanded")
check(db.fetchItems(offset: 0, limit: 50, searchTerm: "   ", favoritesOnly: false).count == 3, "blank search is ignored")

print("favorites and limit")
let toFavorite = db.fetchItems(offset: 0, limit: 1, searchTerm: "beta", favoritesOnly: false)[0]
db.setFavorite(id: toFavorite.id, isFavorite: true)
check(db.fetchItems(offset: 0, limit: 50, searchTerm: nil, favoritesOnly: true).count == 1, "favorites filter returns only favorites")

for index in 0..<10 {
    db.save(capture("filler-\(index)"), historyLimit: 5)
}
items = db.fetchItems(offset: 0, limit: 50, searchTerm: nil, favoritesOnly: false)
check(items.count == 6, "history limit keeps 5 items plus the favorite")
check(items.contains { $0.isFavorite }, "favorites survive trimming")

print("custom title and delete")
let target = items.first { !$0.isFavorite }!
db.setCustomTitle(id: target.id, title: "Meu título")
check(db.fetchItem(id: target.id)?.customTitle == "Meu título", "custom title round-trips")
check(db.fetchItems(offset: 0, limit: 50, searchTerm: "título", favoritesOnly: false).count == 1, "search matches the custom title")
db.delete(id: target.id)
check(db.fetchItem(id: target.id) == nil, "delete removes the row")

print("file cleanup")
let ownedImage = KopStorage.images.appendingPathComponent("selfcheck-owned.png")
let userImage = sandbox.appendingPathComponent("user-owned.png")
try Data([0x89, 0x50]).write(to: ownedImage)
try Data([0x89, 0x50]).write(to: userImage)
db.save(capture("img", type: .image, filePath: ownedImage.path), historyLimit: nil)
db.save(capture("user-img", type: .image, filePath: userImage.path), historyLimit: nil)
db.clearNonFavoriteItems()
check(!FileManager.default.fileExists(atPath: ownedImage.path), "Kop-generated files are cleaned up")
check(FileManager.default.fileExists(atPath: userImage.path), "files outside Kop storage are never deleted")

print("compaction")
let bulkyBytes = 8 * 1024 * 1024
db.save(capture(String(repeating: "x", count: bulkyBytes)), historyLimit: nil)
db.deleteItemsOlderThan(Date().addingTimeInterval(60))
check(db.fetchStorageStats().totalSizeBytes < Int64(bulkyBytes / 8), "bulk delete gives the disk space back")

print("stats")
let stats = db.fetchStorageStats()
check(stats.totalItems == 1, "stats count the surviving favorite")
check(stats.totalSizeBytes > 0, "stats report a size")

print("\nall checks passed")
