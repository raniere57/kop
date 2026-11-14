// Self-check for Kop's storage layer — the logic most likely to break silently.
// Run: ./Scripts/selfcheck.sh
import Foundation
import SQLite3

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
let sandboxImages = sandbox.appendingPathComponent("Images", isDirectory: true)
try FileManager.default.createDirectory(at: sandboxImages, withIntermediateDirectories: true)
let ownedImage = sandboxImages.appendingPathComponent("selfcheck-owned.png")
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
try Data(count: 1_000_000).write(to: sandboxImages.appendingPathComponent("big.png"))
check(db.fetchStorageStats().totalSizeBytes >= stats.totalSizeBytes + 1_000_000, "stats count files in Kop's folders")

print("list preview")
let longText = String(repeating: "a", count: PersistenceManager.listTextPreviewLength + 100) + " needle"
db.save(capture(longText), historyLimit: nil)
let listed = db.fetchItems(offset: 0, limit: 1, searchTerm: "needle", favoritesOnly: false, includePayload: false)
check(listed.count == 1, "search matches text past the preview length")
check(listed.first?.textContent?.count == PersistenceManager.listTextPreviewLength, "list rows carry a truncated text")
check(db.fetchItem(id: listed[0].id)?.textContent == longText, "fetchItem returns the whole text")
let multiByte = String(repeating: "ç😀", count: PersistenceManager.listTextPreviewLength)
db.save(capture(multiByte), historyLimit: nil)
let multiListed = db.fetchItems(offset: 0, limit: 1, searchTerm: "ç😀", favoritesOnly: false, includePayload: false).first?.textContent
check(multiListed == String(multiByte.prefix(PersistenceManager.listTextPreviewLength)), "preview truncates by characters, not bytes")

print("cleanup by updated_at")
let monthAgo = Date().addingTimeInterval(-40 * 86_400)
db.save(capture("old-but-recopied", createdAt: monthAgo), historyLimit: nil)
db.save(capture("old-but-recopied"), historyLimit: nil)
db.save(capture("old-untouched", createdAt: monthAgo), historyLimit: nil)
db.deleteItemsOlderThan(Date().addingTimeInterval(-30 * 86_400))
check(db.fetchItems(offset: 0, limit: 5, searchTerm: "old-but-recopied", favoritesOnly: false).count == 1, "re-copied old item survives")
check(db.fetchItems(offset: 0, limit: 5, searchTerm: "old-untouched", favoritesOnly: false).isEmpty, "untouched old item is deleted")

print("fingerprint")
let payload = Data((0..<100_000).map { UInt8($0 % 251) })
check(kopDigest(prefix: "image", data: payload) == kopDigest(Data("image".utf8) + payload), "incremental hash equals the concatenated one")

print("migration")
private func sql(_ handle: OpaquePointer?, _ text: String) -> [[String]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, text, -1, &statement, nil) == SQLITE_OK else {
        check(false, "sql: \(String(cString: sqlite3_errmsg(handle)))")
        return []
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(statement)).map { index in
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "NULL"
        })
    }
    return rows
}

for withTitle in [false, true] {
    let legacyDir = sandbox.appendingPathComponent("legacy-\(withTitle)", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    var handle: OpaquePointer?
    sqlite3_open(legacyDir.appendingPathComponent("history.sqlite").path, &handle)
    _ = sql(handle, """
    CREATE TABLE clipboard_items (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, text_content TEXT,
    rich_text_data BLOB, binary_data BLOB, file_path TEXT, thumbnail_path TEXT, source_app_name TEXT,
    source_bundle_id TEXT, created_at DOUBLE NOT NULL, updated_at DOUBLE NOT NULL,
    is_favorite INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL)
    """)
    if withTitle { _ = sql(handle, "ALTER TABLE clipboard_items ADD COLUMN custom_title TEXT") }
    _ = sql(handle, """
    INSERT INTO clipboard_items (id, type, text_content, binary_data, file_path, created_at, updated_at, is_favorite, fingerprint)
    VALUES (5, 'image', 'pic', x'DEADBEEF', '/p.png', 1, 2, 1, 'f5'), (9, 'plainText', 'txt', NULL, NULL, 3, 4, 0, 'f9')
    """)
    if withTitle { _ = sql(handle, "UPDATE clipboard_items SET custom_title = 'Título' WHERE id = 9") }
    _ = sql(handle, "UPDATE sqlite_sequence SET seq = 20 WHERE name = 'clipboard_items'")
    sqlite3_close(handle)

    let migrated = PersistenceManager(directory: legacyDir)
    // Queued behind the async migration, so this waits for it.
    let pic = migrated.fetchItem(id: 5)
    let label = withTitle ? "(with custom_title)" : "(without custom_title)"
    check(pic?.binaryData == Data([0xDE, 0xAD, 0xBE, 0xEF]) && pic?.isFavorite == true && pic?.filePath == "/p.png", "blob, favorite and path survive \(label)")
    check(migrated.fetchItem(id: 9)?.customTitle == (withTitle ? "Título" : nil), "custom title survives \(label)")
    migrated.save(capture("after-migration"), historyLimit: nil)
    check(migrated.fetchItems(offset: 0, limit: 1, searchTerm: "after-migration", favoritesOnly: false).first?.id == 21, "AUTOINCREMENT continues past the old sequence \(label)")

    sqlite3_open(legacyDir.appendingPathComponent("history.sqlite").path, &handle)
    let columns = sql(handle, "PRAGMA table_info(clipboard_items)").map { $0[1] }
    check(columns.suffix(3) == ["text_content", "rich_text_data", "binary_data"], "blobs are the last columns \(label)")
    check(sql(handle, "PRAGMA user_version").first == ["1"], "schema version recorded \(label)")
    check(sql(handle, "SELECT count(*) FROM sqlite_master WHERE type = 'index'").first == ["3"], "indexes recreated \(label)")
    sqlite3_close(handle)
}

do {
    let emptyDir = sandbox.appendingPathComponent("legacy-empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    var handle: OpaquePointer?
    sqlite3_open(emptyDir.appendingPathComponent("history.sqlite").path, &handle)
    _ = sql(handle, """
    CREATE TABLE clipboard_items (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, text_content TEXT,
    rich_text_data BLOB, binary_data BLOB, file_path TEXT, thumbnail_path TEXT, source_app_name TEXT,
    source_bundle_id TEXT, created_at DOUBLE NOT NULL, updated_at DOUBLE NOT NULL,
    is_favorite INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL)
    """)
    _ = sql(handle, "INSERT INTO clipboard_items (type, created_at, updated_at, fingerprint) VALUES ('plainText', 1, 1, 'x')")
    _ = sql(handle, "DELETE FROM clipboard_items")
    _ = sql(handle, "UPDATE sqlite_sequence SET seq = 20 WHERE name = 'clipboard_items'")
    sqlite3_close(handle)
    let migrated = PersistenceManager(directory: emptyDir)
    migrated.save(capture("first-after-clear"), historyLimit: nil)
    check(migrated.fetchItems(offset: 0, limit: 1, searchTerm: nil, favoritesOnly: false).first?.id == 21, "AUTOINCREMENT continues on an empty legacy table")
}

print("orphan sweep")
do {
    let fm = FileManager.default
    let dir = sandbox.appendingPathComponent("sweep", isDirectory: true)
    let images = dir.appendingPathComponent("Images", isDirectory: true)
    let thumbs = dir.appendingPathComponent("Thumbnails", isDirectory: true)
    let sibling = dir.appendingPathComponent("ImagesBackup", isDirectory: true)
    for folder in [images, thumbs, sibling] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    let oldOrphan = images.appendingPathComponent("old-orphan.png")
    let recentOrphan = images.appendingPathComponent("recent-orphan.png")
    let oldReferenced = thumbs.appendingPathComponent("old-ref.png")
    let outside = dir.appendingPathComponent("outside.png")
    let siblingFile = sibling.appendingPathComponent("sibling.png")
    let all = [oldOrphan, recentOrphan, oldReferenced, outside, siblingFile]
    for file in all { try Data([1]).write(to: file) }
    PersistenceManager(directory: dir).save(capture("ref", type: .image, thumbnailPath: oldReferenced.path), historyLimit: nil)
    let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
    for file in all where file != recentOrphan {
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: file.path)
    }
    let swept = PersistenceManager(directory: dir)
    _ = swept.fetchStorageStats() // queued behind the launch sweep
    check(!fm.fileExists(atPath: oldOrphan.path), "old unreferenced file is swept")
    check(fm.fileExists(atPath: recentOrphan.path), "recent unreferenced file is kept")
    check(fm.fileExists(atPath: oldReferenced.path), "old referenced file is kept")
    check(fm.fileExists(atPath: outside.path) && fm.fileExists(atPath: siblingFile.path), "files outside Kop's two folders are kept")
    check(!KopStorage.isManaged(siblingFile.path, in: [images]), "sibling folder is not managed")
    check(!KopStorage.isManaged(images.path + "/../outside.png", in: [images]), "'..' does not escape the folder")
    check(KopStorage.reuseIfExists(oldReferenced), "reuse reports an existing file")
    let touched = (try fm.attributesOfItem(atPath: oldReferenced.path))[.modificationDate] as? Date
    check((touched ?? .distantPast) > twoDaysAgo.addingTimeInterval(86_400), "reusing a file refreshes its modification date")
}

let freshDir = sandbox.appendingPathComponent("fresh", isDirectory: true)
try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
let fresh = PersistenceManager(directory: freshDir)
check(fresh.save(capture("first"), historyLimit: nil), "save reports a written row")
var freshHandle: OpaquePointer?
sqlite3_open(freshDir.appendingPathComponent("history.sqlite").path, &freshHandle)
check(sql(freshHandle, "PRAGMA table_info(clipboard_items)").last?[1] == "binary_data", "fresh install gets the new order")
sqlite3_close(freshHandle)

print("\nall checks passed")
