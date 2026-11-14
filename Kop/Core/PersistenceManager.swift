import Foundation
import SQLite3

struct StorageStats {
    let totalItems: Int
    let totalSizeBytes: Int64
    let oldestItemDate: Date?
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let entryColumns = """
id, type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, \
source_app_name, source_bundle_id, created_at, updated_at, is_favorite, custom_title, fingerprint
"""

/// Small scalar columns first and the blobs last, so reading metadata never
/// walks a blob's overflow pages. Tracked in `PRAGMA user_version`.
private let schemaVersion = 1
private let tableColumns = """
id, type, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, \
is_favorite, custom_title, fingerprint, text_content, rich_text_data, binary_data
"""

private func createTableSQL(_ name: String) -> String {
    """
    CREATE TABLE \(name) (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        file_path TEXT,
        thumbnail_path TEXT,
        source_app_name TEXT,
        source_bundle_id TEXT,
        created_at DOUBLE NOT NULL,
        updated_at DOUBLE NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        custom_title TEXT,
        fingerprint TEXT NOT NULL,
        text_content TEXT,
        rich_text_data BLOB,
        binary_data BLOB
    );
    """
}

private let createIndexesSQL = """
CREATE INDEX IF NOT EXISTS idx_clipboard_updated_at ON clipboard_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_clipboard_favorites ON clipboard_items(is_favorite, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_clipboard_fingerprint ON clipboard_items(fingerprint);
"""

final class PersistenceManager {
    static let shared = PersistenceManager()

    /// Rows fetched for the list (`includePayload: false`) carry at most this
    /// many characters of text; fetch the row by id to get all of it.
    static let listTextPreviewLength = 500

    /// False when the database could not be opened, so nothing is being saved.
    var isAvailable: Bool { db != nil }

    /// True while a schema rebuild or VACUUM holds the queue for seconds.
    /// Main-thread callers check it instead of blocking on `queue.sync`;
    /// `.clipboardHistoryChanged` is posted when the work is done.
    var isBusy: Bool {
        busyLock.lock()
        defer { busyLock.unlock() }
        return busy
    }

    private let busyLock = NSLock()
    private var busy = false

    private let dbURL: URL
    /// Kop-owned file folders next to this database (KopStorage's folders for
    /// the shared instance, sandboxed ones in the self-check).
    private let fileDirectories: [URL]
    private let queue = DispatchQueue(label: "kop.persistence.queue")
    private var db: OpaquePointer?

    /// `directory` is injectable so the self-check script can run against a
    /// throwaway database instead of the user's history.
    init(directory: URL = KopStorage.root) {
        dbURL = directory.appendingPathComponent("history.sqlite")
        fileDirectories = ["Images", "Thumbnails"].map { directory.appendingPathComponent($0, isDirectory: true) }
        openDatabase()
        configureConnection()
        // Serial queue: every later call waits behind the schema work, and app
        // launch is not blocked by rebuilding a large history.
        setBusy(true)
        queue.async {
            self.prepareSchemaInternal()
            self.sweepOrphanFilesInternal()
            self.setBusy(false)
        }
    }

    private func setBusy(_ value: Bool) {
        busyLock.lock()
        busy = value
        busyLock.unlock()
        guard !value else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writes

    /// Returns whether a row was written or promoted.
    @discardableResult
    func save(_ capture: ClipboardCapture, historyLimit: Int?) -> Bool {
        queue.sync {
            // Dedupe against the whole history, not just the newest row, so
            // re-copying an older snippet promotes it instead of duplicating it.
            if let existingID = idForFingerprintInternal(capture.fingerprint) {
                return updateTimestamp(for: existingID, at: capture.createdAt)
            }

            let sql = """
            INSERT INTO clipboard_items
            (type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, fingerprint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?);
            """
            var statement: OpaquePointer?
            guard prepare(sql, into: &statement) else { return false }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, capture.type.rawValue, -1, SQLITE_TRANSIENT)
            bindOptionalText(capture.textContent, to: 2, in: statement)
            bindOptionalBlob(capture.richTextData, to: 3, in: statement)
            bindOptionalBlob(capture.binaryData, to: 4, in: statement)
            bindOptionalText(capture.filePath, to: 5, in: statement)
            bindOptionalText(capture.thumbnailPath, to: 6, in: statement)
            bindOptionalText(capture.sourceAppName, to: 7, in: statement)
            bindOptionalText(capture.sourceBundleIdentifier, to: 8, in: statement)
            sqlite3_bind_double(statement, 9, capture.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 10, capture.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 11, capture.fingerprint, -1, SQLITE_TRANSIENT)
            guard step(statement, context: "insert") else { return false }

            trimHistoryIfNeeded(limit: historyLimit)
            return true
        }
    }

    /// Promotes an item to the top of the history without re-capturing it.
    func touch(id: Int64, at date: Date = Date()) {
        queue.sync { _ = updateTimestamp(for: id, at: date) }
    }

    func setFavorite(id: Int64, isFavorite: Bool) {
        execute("UPDATE clipboard_items SET is_favorite = ? WHERE id = ?;") { statement in
            sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
        }
    }

    func setCustomTitle(id: Int64, title: String?) {
        execute("UPDATE clipboard_items SET custom_title = ? WHERE id = ?;") { statement in
            self.bindOptionalText(title, to: 1, in: statement)
            sqlite3_bind_int64(statement, 2, id)
        }
    }

    func delete(id: Int64) {
        queue.sync {
            let orphans = filePathsInternal(where: "id = ?") { statement in
                sqlite3_bind_int64(statement, 1, id)
            }
            runInternal("DELETE FROM clipboard_items WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
            }
            purgeOrphanFilesInternal(orphans)
        }
    }

    func clearNonFavoriteItems() {
        setBusy(true)
        defer { setBusy(false) }
        queue.sync {
            let orphans = filePathsInternal(where: "is_favorite = 0", bind: nil)
            runInternal("DELETE FROM clipboard_items WHERE is_favorite = 0;", bind: nil)
            purgeOrphanFilesInternal(orphans)
            compactInternal()
        }
    }

    func deleteItemsOlderThan(_ date: Date) {
        setBusy(true)
        defer { setBusy(false) }
        queue.sync {
            let orphans = filePathsInternal(where: "is_favorite = 0 AND updated_at < ?") { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            }
            runInternal("DELETE FROM clipboard_items WHERE is_favorite = 0 AND updated_at < ?;") { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            }
            purgeOrphanFilesInternal(orphans)
            compactInternal()
        }
    }

    // MARK: - Reads

    func fetchItems(
        offset: Int,
        limit: Int,
        searchTerm: String?,
        favoritesOnly: Bool,
        includePayload: Bool = true
    ) -> [ClipboardEntry] {
        queue.sync {
            let term = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var conditions: [String] = []
            if !term.isEmpty {
                conditions.append("""
                (text_content LIKE ? ESCAPE '\\' OR file_path LIKE ? ESCAPE '\\' \
                OR source_app_name LIKE ? ESCAPE '\\' OR custom_title LIKE ? ESCAPE '\\')
                """)
            }
            if favoritesOnly {
                conditions.append("is_favorite = 1")
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            // Skipping the blobs keeps list scrolling cheap; the full row is
            // re-fetched on demand when an item is copied or previewed.
            // List rows also carry only a text preview; the WHERE above still
            // matches against the full text.
            let textColumn = includePayload
                ? "text_content"
                : "substr(text_content, 1, \(Self.listTextPreviewLength))"
            let payloadColumns = includePayload ? "rich_text_data, binary_data" : "NULL, NULL"
            let sql = """
            SELECT id, type, \(textColumn), \(payloadColumns), file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, custom_title, fingerprint
            FROM clipboard_items
            \(whereClause)
            ORDER BY updated_at DESC
            LIMIT ? OFFSET ?;
            """
            var statement: OpaquePointer?
            guard prepare(sql, into: &statement) else { return [] }
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            if !term.isEmpty {
                let pattern = "%\(escapedLike(term))%"
                for _ in 0..<4 {
                    sqlite3_bind_text(statement, index, pattern, -1, SQLITE_TRANSIENT)
                    index += 1
                }
            }
            sqlite3_bind_int(statement, index, Int32(limit))
            sqlite3_bind_int(statement, index + 1, Int32(offset))

            var rows: [ClipboardEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(makeEntry(from: statement))
            }
            return rows
        }
    }

    func fetchItem(id: Int64) -> ClipboardEntry? {
        queue.sync {
            var statement: OpaquePointer?
            guard prepare("SELECT \(entryColumns) FROM clipboard_items WHERE id = ? LIMIT 1;", into: &statement) else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return makeEntry(from: statement)
        }
    }

    func fetchLatest() -> ClipboardEntry? {
        queue.sync {
            var statement: OpaquePointer?
            guard prepare("SELECT \(entryColumns) FROM clipboard_items ORDER BY updated_at DESC LIMIT 1;", into: &statement) else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return makeEntry(from: statement)
        }
    }

    func fetchStorageStats() -> StorageStats {
        queue.sync {
            let empty = StorageStats(totalItems: 0, totalSizeBytes: 0, oldestItemDate: nil)
            let sql = """
            SELECT COUNT(*), MIN(updated_at) FROM clipboard_items;
            """
            var statement: OpaquePointer?
            guard prepare(sql, into: &statement) else { return empty }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return empty }

            let oldestTimestamp = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 1)
            return StorageStats(
                totalItems: Int(sqlite3_column_int(statement, 0)),
                totalSizeBytes: diskUsageInternal(),
                oldestItemDate: oldestTimestamp.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    // MARK: - Setup

    private func openDatabase() {
        let result = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        if result != SQLITE_OK {
            NSLog("[Kop] Falha ao abrir o banco (\(result)): \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db)
            db = nil
        }
    }

    private func configureConnection() {
        guard db != nil else { return }
        // WAL keeps reads (panel) from blocking on writes (capture).
        for pragma in [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA busy_timeout = 3000;",
            // Keep the page cache at 2 MB and spill early: the system default
            // spills only after 20,000 pages, so a VACUUM or the schema
            // rebuild would hold ~180 MB in memory.
            "PRAGMA cache_size = -2000;",
            "PRAGMA cache_spill = 500;"
        ] {
            _ = sqlite3_exec(db, pragma, nil, nil, nil)
        }
    }

    private func prepareSchemaInternal() {
        guard db != nil else { return }
        guard tableExists() else {
            // Fresh install: create the final layout directly.
            let sql = createTableSQL("clipboard_items") + createIndexesSQL + "PRAGMA user_version = \(schemaVersion);"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("[Kop] Falha ao criar a tabela: \(String(cString: sqlite3_errmsg(db)))")
            }
            return
        }
        _ = sqlite3_exec(db, createIndexesSQL, nil, nil, nil)
        if !columnExists("custom_title") {
            _ = sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN custom_title TEXT;", nil, nil, nil)
        }
        if userVersion() < schemaVersion, rebuildTableInternal() {
            compactInternal()
        }
    }

    /// Rewrites the table in the blobs-last column order in one transaction;
    /// on any failure it rolls back and the old layout keeps working.
    private func rebuildTableInternal() -> Bool {
        let sql = """
        BEGIN IMMEDIATE;
        DROP TABLE IF EXISTS clipboard_items_new;
        \(createTableSQL("clipboard_items_new"))
        INSERT INTO clipboard_items_new (\(tableColumns)) SELECT \(tableColumns) FROM clipboard_items;
        UPDATE sqlite_sequence
            SET seq = (SELECT MAX(seq) FROM sqlite_sequence WHERE name IN ('clipboard_items', 'clipboard_items_new'))
            WHERE name = 'clipboard_items_new';
        INSERT INTO sqlite_sequence (name, seq)
            SELECT 'clipboard_items_new', seq FROM sqlite_sequence
            WHERE name = 'clipboard_items'
              AND NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'clipboard_items_new');
        DROP TABLE clipboard_items;
        ALTER TABLE clipboard_items_new RENAME TO clipboard_items;
        \(createIndexesSQL)
        PRAGMA user_version = \(schemaVersion);
        COMMIT;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            NSLog("[Kop] Falha ao reorganizar a tabela: \(String(cString: sqlite3_errmsg(db)))")
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }

    private func tableExists() -> Bool {
        var statement: OpaquePointer?
        guard prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_items';", into: &statement) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func userVersion() -> Int {
        var statement: OpaquePointer?
        guard prepare("PRAGMA user_version;", into: &statement) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    private func columnExists(_ name: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(clipboard_items);", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if stringValue(from: statement, at: 1) == name { return true }
        }
        return false
    }

    // MARK: - Internals (already on `queue`)

    private func idForFingerprintInternal(_ fingerprint: String) -> Int64? {
        var statement: OpaquePointer?
        guard prepare("SELECT id FROM clipboard_items WHERE fingerprint = ? LIMIT 1;", into: &statement) else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, fingerprint, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func updateTimestamp(for id: Int64, at date: Date) -> Bool {
        runInternal("UPDATE clipboard_items SET updated_at = ? WHERE id = ?;") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, id)
        }
    }

    private func trimHistoryIfNeeded(limit: Int?) {
        guard let limit else { return }
        let selector = """
        SELECT id FROM clipboard_items
        WHERE is_favorite = 0
        ORDER BY updated_at DESC
        LIMIT -1 OFFSET ?
        """
        let orphans = filePathsInternal(where: "id IN (\(selector))") { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
        }
        runInternal("DELETE FROM clipboard_items WHERE id IN (\(selector));") { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
        }
        purgeOrphanFilesInternal(orphans)
    }

    private func filePathsInternal(where clause: String, bind: ((OpaquePointer?) -> Void)?) -> [String] {
        var statement: OpaquePointer?
        let sql = "SELECT file_path, thumbnail_path FROM clipboard_items WHERE \(clause);"
        guard prepare(sql, into: &statement) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = stringValue(from: statement, at: 0) { paths.append(path) }
            if let path = stringValue(from: statement, at: 1) { paths.append(path) }
        }
        return paths
    }

    /// Deletes only files Kop itself generated and that no surviving row still
    /// points at (two entries can share a content-addressed thumbnail).
    private func purgeOrphanFilesInternal(_ candidates: [String]) {
        let managed = candidates.filter { KopStorage.isManaged($0, in: fileDirectories) }
        guard !managed.isEmpty, let referenced = referencedPathsInternal() else { return }
        ImageThumbnail.shared.removeOrphanFiles(paths: managed, stillReferenced: referenced, managedDirectories: fileDirectories)
    }

    /// Nil when the query failed, so an error is never read as "nothing is
    /// referenced" (which would delete every file).
    private func referencedPathsInternal() -> Set<String>? {
        var statement: OpaquePointer?
        guard prepare("SELECT file_path, thumbnail_path FROM clipboard_items;", into: &statement) else { return nil }
        defer { sqlite3_finalize(statement) }
        var referenced = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let path = stringValue(from: statement, at: 0) { referenced.insert(path) }
            if let path = stringValue(from: statement, at: 1) { referenced.insert(path) }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? referenced : nil
    }

    /// Removes files no row references, e.g. PNGs exported when an inline image
    /// is copied back out. Recent files stay: one may still be on the pasteboard.
    private func sweepOrphanFilesInternal() {
        // Referenced paths are read first so the age check sits right next to
        // the removal: a file reused (and touched) in the meantime is fresh.
        guard db != nil, let referenced = referencedPathsInternal() else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let manager = FileManager.default
        let candidates = fileDirectories.flatMap { directory -> [String] in
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.map { directory.appendingPathComponent($0).path }.filter { path in
                let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                return modified.map { $0 < cutoff } ?? false
            }
        }
        ImageThumbnail.shared.removeOrphanFiles(paths: candidates, stillReferenced: referenced, managedDirectories: fileDirectories)
    }

    /// Database, its WAL and Kop's file folders: what Kop really takes on disk.
    private func diskUsageInternal() -> Int64 {
        let manager = FileManager.default
        let folderFiles = fileDirectories.flatMap { directory in
            ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).map { directory.appendingPathComponent($0).path }
        }
        return ([dbURL.path, dbURL.path + "-wal"] + folderFiles).reduce(Int64(0)) { total, path in
            total + (((try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// SQLite keeps deleted pages inside the file for reuse, so a bulk delete
    /// only frees disk space after an explicit VACUUM (and, under WAL, a
    /// truncating checkpoint).
    // ponytail: VACUUM blocks the caller for a few seconds on a big history;
    // move the cleanup off the main thread if that becomes noticeable.
    private func compactInternal() {
        guard db != nil else { return }
        for sql in ["VACUUM;", "PRAGMA wal_checkpoint(TRUNCATE);"] where sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[Kop] Falha ao compactar (\(sql)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func execute(_ sql: String, bind: @escaping (OpaquePointer?) -> Void) {
        queue.sync { _ = runInternal(sql, bind: bind) }
    }

    @discardableResult
    private func runInternal(_ sql: String, bind: ((OpaquePointer?) -> Void)?) -> Bool {
        var statement: OpaquePointer?
        guard prepare(sql, into: &statement) else { return false }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        return step(statement, context: sql)
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) -> Bool {
        guard db != nil else { return false }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("[Kop] SQL inválido: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    @discardableResult
    private func step(_ statement: OpaquePointer?, context: String) -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            NSLog("[Kop] Falha ao executar (\(context)): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func escapedLike(_ term: String) -> String {
        term.replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func makeEntry(from statement: OpaquePointer?) -> ClipboardEntry {
        ClipboardEntry(
            id: sqlite3_column_int64(statement, 0),
            type: ClipboardItemType(rawValue: stringValue(from: statement, at: 1) ?? "") ?? .plainText,
            textContent: stringValue(from: statement, at: 2),
            richTextData: dataValue(from: statement, at: 3),
            binaryData: dataValue(from: statement, at: 4),
            filePath: stringValue(from: statement, at: 5),
            thumbnailPath: stringValue(from: statement, at: 6),
            sourceAppName: stringValue(from: statement, at: 7),
            sourceBundleIdentifier: stringValue(from: statement, at: 8),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            isFavorite: sqlite3_column_int(statement, 11) == 1,
            customTitle: stringValue(from: statement, at: 12),
            fingerprint: stringValue(from: statement, at: 13) ?? ""
        )
    }

    private func stringValue(from statement: OpaquePointer?, at index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func dataValue(from statement: OpaquePointer?, at index: Int32) -> Data? {
        let bytes = sqlite3_column_blob(statement, index)
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let bytes, count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func bindOptionalText(_ text: String?, to index: Int32, in statement: OpaquePointer?) {
        guard let text else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalBlob(_ data: Data?, to index: Int32, in statement: OpaquePointer?) {
        guard let data else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }
}
