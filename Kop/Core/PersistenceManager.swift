import Foundation
import SQLite3

struct StorageStats {
    let totalItems: Int
    let totalSizeBytes: Int64
    let oldestItemDate: Date?
}

final class PersistenceManager {
    static let shared = PersistenceManager()

    private let dbURL: URL
    private let queue = DispatchQueue(label: "kop.persistence.queue")
    private var db: OpaquePointer?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Kop", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dbURL = folder.appendingPathComponent("history.sqlite")
        openDatabase()
        createTableIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    func save(_ capture: ClipboardCapture, historyLimit: Int?) {
        queue.sync {
            if let last = fetchLatestInternal(), last.fingerprint == capture.fingerprint {
                updateTimestamp(for: last.id, at: capture.createdAt)
                return
            }

            let sql = """
            INSERT INTO clipboard_items
            (type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, fingerprint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, capture.type.rawValue, -1, transient)
            bindOptionalText(capture.textContent, to: 2, in: statement)
            bindOptionalBlob(capture.richTextData, to: 3, in: statement)
            bindOptionalBlob(capture.binaryData, to: 4, in: statement)
            bindOptionalText(capture.filePath, to: 5, in: statement)
            bindOptionalText(capture.thumbnailPath, to: 6, in: statement)
            bindOptionalText(capture.sourceAppName, to: 7, in: statement)
            bindOptionalText(capture.sourceBundleIdentifier, to: 8, in: statement)
            sqlite3_bind_double(statement, 9, capture.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 10, capture.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 11, capture.fingerprint, -1, transient)
            sqlite3_step(statement)

            trimHistoryIfNeeded(limit: historyLimit)
        }
    }

    func fetchItems(offset: Int, limit: Int, searchTerm: String?) -> [ClipboardEntry] {
        queue.sync {
            let hasSearch = !(searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let sql: String
            if hasSearch {
                sql = """
                SELECT id, type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, fingerprint
                FROM clipboard_items
                WHERE text_content LIKE ? OR file_path LIKE ? OR source_app_name LIKE ?
                ORDER BY updated_at DESC
                LIMIT ? OFFSET ?;
                """
            } else {
                sql = """
                SELECT id, type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, fingerprint
                FROM clipboard_items
                ORDER BY updated_at DESC
                LIMIT ? OFFSET ?;
                """
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            if hasSearch {
                let pattern = "%\(searchTerm!.trimmingCharacters(in: .whitespacesAndNewlines))%"
                sqlite3_bind_text(statement, index, pattern, -1, transient)
                sqlite3_bind_text(statement, index + 1, pattern, -1, transient)
                sqlite3_bind_text(statement, index + 2, pattern, -1, transient)
                index += 3
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

    func fetchLatest() -> ClipboardEntry? {
        queue.sync { fetchLatestInternal() }
    }

    func setFavorite(id: Int64, isFavorite: Bool) {
        queue.sync {
            let sql = "UPDATE clipboard_items SET is_favorite = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
        }
    }

    func delete(id: Int64) {
        queue.sync {
            let sql = "DELETE FROM clipboard_items WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_step(statement)
        }
    }

    func clearNonFavoriteItems() {
        queue.sync {
            _ = sqlite3_exec(db, "DELETE FROM clipboard_items WHERE is_favorite = 0;", nil, nil, nil)
        }
    }

    func fetchStorageStats() -> StorageStats {
        queue.sync {
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
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return StorageStats(totalItems: 0, totalSizeBytes: 0, oldestItemDate: nil)
            }
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return StorageStats(totalItems: 0, totalSizeBytes: 0, oldestItemDate: nil)
            }

            let payloadBytes = sqlite3_column_int64(statement, 1)
            let dbSizeBytes = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0
            let oldestTimestamp = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
            return StorageStats(
                totalItems: Int(sqlite3_column_int(statement, 0)),
                totalSizeBytes: max(payloadBytes, dbSizeBytes),
                oldestItemDate: oldestTimestamp.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func deleteItemsOlderThan(_ date: Date) {
        queue.sync {
            let sql = "DELETE FROM clipboard_items WHERE is_favorite = 0 AND created_at < ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    private func openDatabase() {
        sqlite3_open(dbURL.path, &db)
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
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func fetchLatestInternal() -> ClipboardEntry? {
        let sql = """
        SELECT id, type, text_content, rich_text_data, binary_data, file_path, thumbnail_path, source_app_name, source_bundle_id, created_at, updated_at, is_favorite, fingerprint
        FROM clipboard_items
        ORDER BY updated_at DESC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return makeEntry(from: statement)
    }

    private func updateTimestamp(for id: Int64, at date: Date) {
        let sql = "UPDATE clipboard_items SET updated_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    private func trimHistoryIfNeeded(limit: Int?) {
        guard let limit else { return }
        let sql = """
        DELETE FROM clipboard_items
        WHERE id IN (
            SELECT id FROM clipboard_items
            WHERE is_favorite = 0
            ORDER BY updated_at DESC
            LIMIT -1 OFFSET ?
        );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        sqlite3_step(statement)
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
            fingerprint: stringValue(from: statement, at: 12) ?? UUID().uuidString
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
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    private func bindOptionalBlob(_ data: Data?, to index: Int32, in statement: OpaquePointer?) {
        guard let data else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
