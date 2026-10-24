import Foundation
import SQLite3

struct HistoryItem: Identifiable, Hashable {
    var id: Int64
    var date: Date
    var app: String
    var raw: String
    var text: String
    var language: String
    var duration: Double
    var mode: String
}

/// Local dictation history stored in SQLite.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    @Published private(set) var revision = 0

    private init() {
        guard sqlite3_open(Paths.history.path, &db) == SQLITE_OK else { return }
        exec("""
        CREATE TABLE IF NOT EXISTS history(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, app TEXT, raw TEXT, text TEXT,
          lang TEXT, duration REAL, mode TEXT);
        CREATE INDEX IF NOT EXISTS history_ts ON history(ts);
        """)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func add(app: String, raw: String, text: String, language: String, duration: Double, mode: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO history(ts, app, raw, text, lang, duration, mode) VALUES(?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, app, -1, transient)
        sqlite3_bind_text(stmt, 3, raw, -1, transient)
        sqlite3_bind_text(stmt, 4, text, -1, transient)
        sqlite3_bind_text(stmt, 5, language, -1, transient)
        sqlite3_bind_double(stmt, 6, duration)
        sqlite3_bind_text(stmt, 7, mode, -1, transient)
        sqlite3_step(stmt)
        revision += 1
    }

    func items(search: String = "", limit: Int = 300) -> [HistoryItem] {
        var stmt: OpaquePointer?
        let sql = "SELECT id, ts, app, raw, text, lang, duration, mode FROM history WHERE text LIKE ? OR raw LIKE ? ORDER BY ts DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let like = "%\(search)%"
        sqlite3_bind_text(stmt, 1, like, -1, transient)
        sqlite3_bind_text(stmt, 2, like, -1, transient)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        func col(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        var result: [HistoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(HistoryItem(id: sqlite3_column_int64(stmt, 0),
                                      date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                      app: col(2), raw: col(3), text: col(4), language: col(5),
                                      duration: sqlite3_column_double(stmt, 6), mode: col(7)))
        }
        return result
    }

    func stats() -> (count: Int, words: Int, minutes: Double) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text, duration FROM history", -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0) }
        defer { sqlite3_finalize(stmt) }
        var count = 0, words = 0
        var seconds = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            count += 1
            let text = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            words += text.split(whereSeparator: { $0.isWhitespace }).count
            seconds += sqlite3_column_double(stmt, 1)
        }
        return (count, words, seconds / 60)
    }

    func delete(_ id: Int64) {
        exec("DELETE FROM history WHERE id = \(id)")
        revision += 1
    }

    func clear() {
        exec("DELETE FROM history")
        revision += 1
    }
}
