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

final class PersistenceManager {
    static let shared = PersistenceManager()

    /// Rows fetched for the list (`includePayload: false`) carry at most this
    /// many characters of text; fetch the row by id to get all of it.
    static let listTextPreviewLength = 500

    /// False when the database could not be opened, so nothing is being saved.
    var isAvailable: Bool { db != nil }

    private let dbURL: URL
    private let queue = DispatchQueue(label: "kop.persistence.queue")
    private var db: OpaquePointer?

    /// `directory` is injectable so the self-check script can run against a
    /// throwaway database instead of the user's history.
    init(directory: URL = KopStorage.root) {
        dbURL = directory.appendingPathComponent("history.sqlite")
        openDatabase()
        configureConnection()
        createTableIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writes

    func save(_ capture: ClipboardCapture, historyLimit: Int?) {
        queue.sync {
            // Dedupe against the whole history, not just the newest row, so
            // re-copying an older snippet promotes it instead of duplicating it.
            if let existingID = idForFingerprintInternal(capture.fingerprint) {
                updateTimestamp(for: existingID, at: capture.createdAt)
                return
            }

            let sql = """
            INSERT INTO clipboard_items
            (type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, fingerprint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?);
            """
            var statement: OpaquePointer?
            guard prepare(sql, into: &statement) else { return }
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
            step(statement, context: "insert")

            trimHistoryIfNeeded(limit: historyLimit)
        }
    }

    /// Promotes an item to the top of the history without re-capturing it.
    func touch(id: Int64, at date: Date = Date()) {
        queue.sync { updateTimestamp(for: id, at: date) }
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
        queue.sync {
            let orphans = filePathsInternal(where: "is_favorite = 0", bind: nil)
            runInternal("DELETE FROM clipboard_items WHERE is_favorite = 0;", bind: nil)
            purgeOrphanFilesInternal(orphans)
            compactInternal()
        }
    }

    func deleteItemsOlderThan(_ date: Date) {
        queue.sync {
            let orphans = filePathsInternal(where: "is_favorite = 0 AND created_at < ?") { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            }
            runInternal("DELETE FROM clipboard_items WHERE is_favorite = 0 AND created_at < ?;") { statement in
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
            let payloadColumns = includePayload ? "rich_text_data, binary_data" : "NULL, NULL"
            let sql = """
            SELECT id, type, text_content, \(payloadColumns), file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, custom_title, fingerprint
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
            SELECT
                COUNT(*),
                COALESCE(SUM(
                    COALESCE(length(binary_data), 0) +
                    COALESCE(length(rich_text_data), 0) +
                    COALESCE(length(text_content), 0)
                ), 0),
                MIN(created_at)
            FROM clipboard_items;
            """
            var statement: OpaquePointer?
            guard prepare(sql, into: &statement) else { return empty }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return empty }

            let payloadBytes = sqlite3_column_int64(statement, 1)
            let dbSizeBytes = ((try? FileManager.default.attributesOfItem(atPath: dbURL.path))?[.size] as? Int64) ?? 0
            let oldestTimestamp = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
            return StorageStats(
                totalItems: Int(sqlite3_column_int(statement, 0)),
                totalSizeBytes: max(payloadBytes, dbSizeBytes),
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
            "PRAGMA temp_store = MEMORY;"
        ] {
            _ = sqlite3_exec(db, pragma, nil, nil, nil)
        }
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            text_content TEXT,
            rich_text_data BLOB,
            binary_data BLOB,
            file_path TEXT,
            thumbnail_path TEXT,
            source_app_name TEXT,
            source_bundle_id TEXT,
            created_at DOUBLE NOT NULL,
            updated_at DOUBLE NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            fingerprint TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_clipboard_updated_at ON clipboard_items(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clipboard_favorites ON clipboard_items(is_favorite, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clipboard_fingerprint ON clipboard_items(fingerprint);
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
        if !columnExists("custom_title") {
            _ = sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN custom_title TEXT;", nil, nil, nil)
        }
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

    private func updateTimestamp(for id: Int64, at date: Date) {
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
        let managed = candidates.filter(KopStorage.isManaged)
        guard !managed.isEmpty else { return }
        var referenced = Set<String>()
        var statement: OpaquePointer?
        if prepare("SELECT file_path, thumbnail_path FROM clipboard_items;", into: &statement) {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = stringValue(from: statement, at: 0) { referenced.insert(path) }
                if let path = stringValue(from: statement, at: 1) { referenced.insert(path) }
            }
        }
        sqlite3_finalize(statement)
        ImageThumbnail.shared.removeOrphanFiles(paths: managed, stillReferenced: referenced)
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
        queue.sync { runInternal(sql, bind: bind) }
    }

    private func runInternal(_ sql: String, bind: ((OpaquePointer?) -> Void)?) {
        var statement: OpaquePointer?
        guard prepare(sql, into: &statement) else { return }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        step(statement, context: sql)
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) -> Bool {
        guard db != nil else { return false }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("[Kop] SQL inválido: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func step(_ statement: OpaquePointer?, context: String) {
        let result = sqlite3_step(statement)
        if result != SQLITE_DONE && result != SQLITE_ROW {
            NSLog("[Kop] Falha ao executar (\(context)): \(String(cString: sqlite3_errmsg(db)))")
        }
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
