import Foundation
import SQLite3

/// Translation cache: SQLite on disk (survives restarts) + small in-memory LRU in front of it.
/// Keyed per translated segment (one line / text node), so repeated lines hit even inside different texts.
final class TranslationCache: @unchecked Sendable {
    static let shared = TranslationCache()

    private let lock = NSLock()
    private var db: OpaquePointer?
    private var getStmt: OpaquePointer?
    private var putStmt: OpaquePointer?
    private var touchStmt: OpaquePointer?
    private var memory: [String: String] = [:]
    private var memoryOrder: [String] = []
    private let memoryLimit = 5_000
    private var writesSincePrune = 0

    // Settings (mirrored from UserDefaults by the controller).
    var enabled = true
    var maxEntries = 200_000

    private(set) var hits = 0
    private(set) var misses = 0

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["TRANSLATEAPI_CACHE"] { return URL(fileURLWithPath: override) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beonyeok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.sqlite")
    }

    init(path: URL = TranslationCache.fileURL) {
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            db = nil; return
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS cache (
              src TEXT NOT NULL, tgt TEXT NOT NULL, text TEXT NOT NULL,
              result TEXT NOT NULL, used INTEGER NOT NULL,
              PRIMARY KEY (src, tgt, text)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS cache_used ON cache(used);
            """)
        sqlite3_prepare_v2(db, "SELECT result FROM cache WHERE src=? AND tgt=? AND text=?", -1, &getStmt, nil)
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO cache (src,tgt,text,result,used) VALUES (?,?,?,?,?)", -1, &putStmt, nil)
        sqlite3_prepare_v2(db, "UPDATE cache SET used=? WHERE src=? AND tgt=? AND text=?", -1, &touchStmt, nil)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer?, _ values: [String]) {
        for (i, v) in values.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, Self.transient) }
    }

    private func memKey(_ src: String, _ tgt: String, _ text: String) -> String { "\(src)\u{1F}\(tgt)\u{1F}\(text)" }

    /// Looks up many segments at once. Returns results aligned with `texts` (nil = miss).
    func lookup(_ texts: [String], src: String, tgt: String) -> [String?] {
        guard enabled else { return texts.map { _ in nil } }
        return lock.withLock {
            let now = Int64(Date().timeIntervalSince1970)
            return texts.map { text in
                let k = memKey(src, tgt, text)
                if let m = memory[k] { hits += 1; return m }
                guard let getStmt else { misses += 1; return nil }
                sqlite3_reset(getStmt); bind(getStmt, [src, tgt, text])
                if sqlite3_step(getStmt) == SQLITE_ROW, let c = sqlite3_column_text(getStmt, 0) {
                    let r = String(cString: c)
                    hits += 1
                    remember(k, r)
                    // Refresh last-used time (LRU eviction on disk).
                    sqlite3_reset(touchStmt)
                    sqlite3_bind_int64(touchStmt, 1, now)
                    sqlite3_bind_text(touchStmt, 2, src, -1, Self.transient)
                    sqlite3_bind_text(touchStmt, 3, tgt, -1, Self.transient)
                    sqlite3_bind_text(touchStmt, 4, text, -1, Self.transient)
                    sqlite3_step(touchStmt)
                    return r
                }
                misses += 1
                return nil
            }
        }
    }

    func store(_ pairs: [(String, String)], src: String, tgt: String) {
        guard enabled, !pairs.isEmpty else { return }
        lock.withLock {
            let now = Int64(Date().timeIntervalSince1970)
            exec("BEGIN")
            for (text, result) in pairs {
                remember(memKey(src, tgt, text), result)
                guard let putStmt else { continue }
                sqlite3_reset(putStmt)
                bind(putStmt, [src, tgt, text, result])
                sqlite3_bind_int64(putStmt, 5, now)
                sqlite3_step(putStmt)
            }
            exec("COMMIT")
            writesSincePrune += pairs.count
            if writesSincePrune > 1_000 { writesSincePrune = 0; pruneLocked() }
        }
    }

    private func remember(_ k: String, _ v: String) {
        if memory[k] == nil {
            memoryOrder.append(k)
            if memoryOrder.count > memoryLimit {
                let drop = memoryOrder.prefix(memoryLimit / 5)
                drop.forEach { memory[$0] = nil }
                memoryOrder.removeFirst(drop.count)
            }
        }
        memory[k] = v
    }

    /// Keeps the most recently used `maxEntries` rows.
    private func pruneLocked() {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT used FROM cache ORDER BY used DESC LIMIT 1 OFFSET ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(maxEntries))
            if sqlite3_step(stmt) == SQLITE_ROW {
                let cutoff = sqlite3_column_int64(stmt, 0)
                exec("DELETE FROM cache WHERE used <= \(cutoff)")
            }
        }
        sqlite3_finalize(stmt)
    }

    var count: Int {
        lock.withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cache", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return memory.count }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func clear() {
        lock.withLock {
            exec("DELETE FROM cache; VACUUM;")
            memory.removeAll(); memoryOrder.removeAll()
            hits = 0; misses = 0
        }
    }

    var stats: (hits: Int, misses: Int) { lock.withLock { (hits, misses) } }
}
