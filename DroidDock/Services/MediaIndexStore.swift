import Foundation
import SQLite3

/// 基于系统 SQLite3 的媒体元数据持久化索引（表 `media_index`），用于重连秒开相册与增量刷新。
actor MediaIndexStore {
    private let handleBox: SQLiteHandleBox?
    private var db: OpaquePointer? { handleBox?.pointer }
    private let databaseURL: URL
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.databaseURL = cachesRoot
                .appendingPathComponent("com.droiddock.app", isDirectory: true)
                .appendingPathComponent("media_index.sqlite3")
        }
        self.handleBox = Self.openAndPrepareSchema(url: self.databaseURL)
    }

    /// 读取设备指定存储上缓存的媒体节点列表（按修改时间降序）。
    func loadMedia(deviceID: String, storage: UInt32, limit: Int = 5000) -> [RemoteNode] {
        guard let db else { return [] }
        let sql = """
        SELECT node_id, path, name, size, mtime, kind
        FROM media_index
        WHERE device = ? AND storage = ?
        ORDER BY mtime DESC, name DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, deviceID, -1, transientDestructor)
        sqlite3_bind_int64(stmt, 2, Int64(storage))
        sqlite3_bind_int64(stmt, 3, Int64(max(1, limit)))

        var nodes: [RemoteNode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let pathC = sqlite3_column_text(stmt, 1),
                  let nameC = sqlite3_column_text(stmt, 2),
                  let kindC = sqlite3_column_text(stmt, 5) else {
                continue
            }
            let size = UInt64(max(0, sqlite3_column_int64(stmt, 3)))
            let modified: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let kind = Self.decodeMediaKind(String(cString: kindC))

            nodes.append(RemoteNode(
                id: String(cString: idC),
                storageID: storage,
                path: String(cString: pathC),
                name: String(cString: nameC),
                isDirectory: false,
                size: size,
                modified: modified,
                kind: kind
            ))
        }
        return nodes
    }

    /// 全量增量同步指定设备存储上的媒体索引。
    func syncMedia(deviceID: String, storage: UInt32, nodes: [RemoteNode]) {
        guard let db else { return }
        guard Self.execute(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;") else { return }

        let deleteSQL = "DELETE FROM media_index WHERE device = ? AND storage = ?;"
        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &delStmt, nil) == SQLITE_OK, let delStmt else {
            _ = Self.execute(db: db, sql: "ROLLBACK;")
            return
        }
        sqlite3_bind_text(delStmt, 1, deviceID, -1, transientDestructor)
        sqlite3_bind_int64(delStmt, 2, Int64(storage))
        let deleteOK = sqlite3_step(delStmt) == SQLITE_DONE
        sqlite3_finalize(delStmt)
        guard deleteOK else {
            _ = Self.execute(db: db, sql: "ROLLBACK;")
            return
        }

        let insertSQL = """
        INSERT OR REPLACE INTO media_index (device, storage, node_id, path, name, size, mtime, kind)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var insStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insStmt, nil) == SQLITE_OK, let insStmt else {
            _ = Self.execute(db: db, sql: "ROLLBACK;")
            return
        }
        defer { sqlite3_finalize(insStmt) }

        for node in nodes where !node.isDirectory {
            sqlite3_reset(insStmt)
            sqlite3_clear_bindings(insStmt)

            sqlite3_bind_text(insStmt, 1, deviceID, -1, transientDestructor)
            sqlite3_bind_int64(insStmt, 2, Int64(storage))
            sqlite3_bind_text(insStmt, 3, node.id, -1, transientDestructor)
            sqlite3_bind_text(insStmt, 4, node.path, -1, transientDestructor)
            sqlite3_bind_text(insStmt, 5, node.name, -1, transientDestructor)
            sqlite3_bind_int64(insStmt, 6, Int64(clamping: node.size))
            if let modified = node.modified {
                sqlite3_bind_double(insStmt, 7, modified.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(insStmt, 7)
            }
            sqlite3_bind_text(insStmt, 8, Self.encodeMediaKind(node.kind), -1, transientDestructor)

            if sqlite3_step(insStmt) != SQLITE_DONE {
                _ = Self.execute(db: db, sql: "ROLLBACK;")
                return
            }
        }

        _ = Self.execute(db: db, sql: "COMMIT;")
    }

    /// 移除已删除路径的索引条目。
    func removeMedia(deviceID: String, storage: UInt32, paths: [String]) {
        guard let db, !paths.isEmpty else { return }
        let sql = "DELETE FROM media_index WHERE device = ? AND storage = ? AND (path = ? OR path LIKE ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        for path in paths {
            let normalized = PathUtils.normalize(path)
            let prefixPattern = normalized == "/" ? "/%" : normalized + "/%"
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, deviceID, -1, transientDestructor)
            sqlite3_bind_int64(stmt, 2, Int64(storage))
            sqlite3_bind_text(stmt, 3, normalized, -1, transientDestructor)
            sqlite3_bind_text(stmt, 4, prefixPattern, -1, transientDestructor)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - SQLite 初始化与辅助

    private static func openAndPrepareSchema(url: URL) -> SQLiteHandleBox? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Log.media.error("创建媒体索引目录失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }

        var dbPtr: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &dbPtr, flags, nil) == SQLITE_OK, let dbPtr else {
            if let dbPtr { sqlite3_close_v2(dbPtr) }
            Log.media.error("打开媒体索引数据库失败：\(url.path, privacy: .public)")
            return nil
        }

        sqlite3_busy_timeout(dbPtr, 2000)
        let schemaSQL = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS media_index (
            device TEXT NOT NULL,
            storage INTEGER NOT NULL,
            node_id TEXT NOT NULL,
            path TEXT NOT NULL,
            name TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL,
            kind TEXT NOT NULL,
            PRIMARY KEY (device, storage, path)
        );
        CREATE INDEX IF NOT EXISTS idx_media_device_storage_mtime
        ON media_index(device, storage, mtime DESC);
        """
        guard execute(db: dbPtr, sql: schemaSQL) else {
            sqlite3_close_v2(dbPtr)
            return nil
        }
        return SQLiteHandleBox(pointer: dbPtr)
    }

    @discardableResult
    private static func execute(db: OpaquePointer, sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if code != SQLITE_OK {
            let text = errMsg.map { String(cString: $0) } ?? "SQLite error \(code)"
            sqlite3_free(errMsg)
            Log.media.error("SQLite 执行失败：\(text, privacy: .public)")
            return false
        }
        return true
    }

    private static func encodeMediaKind(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .document: return "document"
        case .other: return "other"
        }
    }

    private static func decodeMediaKind(_ raw: String) -> MediaKind {
        switch raw {
        case "photo": return .photo
        case "video": return .video
        case "audio": return .audio
        case "document": return .document
        default: return .other
        }
    }
}

private final class SQLiteHandleBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}
