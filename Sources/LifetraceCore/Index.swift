import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct Seg {
    public var seg: String
    public var part: Int
    public var startMs: Int64
    public var endMs: Int64
    public var dur: Double
    public var active: Double
    public var idle: Double
    public var glance: Bool
    public var reason: String
    public var app: String?
    public var bundle: String?
    public var title: String?
    public var doc: String?
    public var url: String?
    public var host: String?

    public init(_ e: Event) {
        seg = e.str("seg") ?? ""
        part = Int(e.int("part") ?? 1)
        startMs = e.str("start").flatMap { Zone.parse($0) } ?? e.ts
        endMs = e.str("end").flatMap { Zone.parse($0) } ?? e.ts
        dur = e["dur_s"]?.dbl ?? 0; active = e["active_s"]?.dbl ?? 0; idle = e["idle_s"]?.dbl ?? 0
        glance = e["glance"]?.bool ?? false; reason = e.str("reason") ?? ""
        app = e.str("app"); bundle = e.str("bundle"); title = e.str("title")
        doc = e.str("doc"); url = e.str("url"); host = e.str("host")
    }

    public var appKey: String { bundle ?? app ?? "?" }
}

public enum IndexError: Error { case open(String) }

/// Derived SQLite (WAL) index over the JSONL log. Always rebuildable; never the source of truth.
public final class Index {
    static let layout = "4"
    var db: OpaquePointer?
    let paths: Paths

    public init(_ paths: Paths) throws {
        self.paths = paths
        paths.ensure()
        guard sqlite3_open(paths.index, &db) == SQLITE_OK else { throw IndexError.open(paths.index) }
        sqlite3_busy_timeout(db, 5000)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        if scalarText("SELECT v FROM meta WHERE k='layout'") != Index.layout {
            exec("""
            DROP TABLE IF EXISTS events; DROP TABLE IF EXISTS segments; DROP TABLE IF EXISTS files;
            DROP TABLE IF EXISTS sources; DROP TABLE IF EXISTS fts;
            CREATE TABLE events(file TEXT, line INTEGER, ts_ms INTEGER, day TEXT, type TEXT, seg TEXT, json TEXT, PRIMARY KEY(file, line));
            CREATE INDEX events_ts ON events(ts_ms);
            CREATE INDEX events_seg ON events(seg);
            CREATE TABLE segments(seg TEXT, part INTEGER, start_ms INTEGER, end_ms INTEGER, day TEXT, app TEXT, bundle TEXT,
              title TEXT, doc TEXT, url TEXT, host TEXT, dur_s REAL, active_s REAL, idle_s REAL, glance INTEGER, reason TEXT,
              json TEXT, PRIMARY KEY(seg, part));
            CREATE INDEX segments_start ON segments(start_ms);
            CREATE TABLE files(name TEXT PRIMARY KEY, bytes INTEGER, lines INTEGER);
            CREATE TABLE sources(source TEXT, id TEXT, ts_ms INTEGER, day TEXT, type TEXT, json TEXT, PRIMARY KEY(source, id));
            CREATE INDEX sources_ts ON sources(ts_ms);
            CREATE VIRTUAL TABLE fts USING fts5(text, kind UNINDEXED, ts_ms UNINDEXED, source UNINDEXED, app UNINDEXED,
              ref UNINDEXED, file UNINDEXED, tokenize='trigram');
            INSERT OR REPLACE INTO meta VALUES('layout', '\(Index.layout)');
            """)
        }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK ? st : nil
    }

    func bind(_ st: OpaquePointer?, _ vals: [Any?]) {
        for (n, v) in vals.enumerated() {
            let i = Int32(n + 1)
            switch v {
            case let s as String: sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT)
            case let x as Int64: sqlite3_bind_int64(st, i, x)
            case let x as Int: sqlite3_bind_int64(st, i, Int64(x))
            case let x as Double: sqlite3_bind_double(st, i, x)
            case let x as Bool: sqlite3_bind_int(st, i, x ? 1 : 0)
            default: sqlite3_bind_null(st, i)
            }
        }
    }

    func scalarText(_ sql: String) -> String? {
        guard let st = prepare(sql) else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(st, i).map { String(cString: $0) }
    }

    /// Text worth searching in one of our own records: (kind, text).
    static func searchable(_ e: Event) -> (String, String)? {
        switch e.type {
        case "content.snapshot", "content.selection": return e.str("text").map { (String(e.type.dropFirst(8)), $0) }
        case "focus.app", "focus.window", "focus.title":
            guard e.str("title") != nil || e.str("url") != nil || e.str("doc") != nil else { return nil }
            return ("title", [e.str("app"), e.str("title"), e.str("url") ?? e.str("doc")].compactMap { $0 }.joined(separator: "  "))
        default: return nil
        }
    }

    /// All string values of a source record except bookkeeping fields, joined (capped at 8 KB).
    static func sourceText(_ e: Event) -> String {
        var parts: [String] = []
        func walk(_ j: J) {
            switch j {
            case .s(let v): parts.append(v)
            case .a(let xs): xs.forEach(walk)
            case .o(let kv): kv.forEach { walk($0.1) }
            default: break
            }
        }
        for (k, v) in e.fields where !["source", "id"].contains(k) && !k.hasSuffix("_id") && !k.hasSuffix("hash") { walk(v) }
        return TextCap.utf8Prefix(parts.joined(separator: "  "), 8192)
    }

    /// Reads the complete lines appended to `path` since byte `offset`; calls `each(lineNumber, text)`.
    /// A partial last line is left for the next call. Returns the new offset and line count.
    func readNew(_ path: String, offset: Int64, lines: Int64, _ each: (Int64, String) -> Void) -> (Int64, Int64)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        try? fh.seek(toOffset: UInt64(offset))
        let data = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        guard let lastNL = data.lastIndex(of: 10) else { return nil }
        let chunk = data[data.startIndex...lastNL]
        var n = lines
        for raw in chunk.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            n += 1
            if let text = String(data: raw, encoding: .utf8) { each(n, text) }
        }
        return (offset + Int64(chunk.count), n)
    }

    /// Indexes bytes appended to day files (own events and external sources) since the last call.
    /// Own files that shrank are re-indexed; source records are deduplicated on (source, id).
    /// All-or-nothing: records and file offsets are committed in one transaction; on any SQLite error
    /// (e.g. the write lock is busy) it rolls back, keeps the old offsets and returns nil.
    @discardableResult
    public func catchUp() -> Int? { ingest(reset: false) }

    func ingest(reset: Bool) -> Int? {
        guard exec("BEGIN IMMEDIATE") else { return nil }
        var ok = true
        func step(_ st: OpaquePointer?, _ vals: [Any?]) {
            guard ok else { return }
            guard let st else { ok = false; return }
            sqlite3_reset(st); sqlite3_clear_bindings(st); bind(st, vals)
            if sqlite3_step(st) != SQLITE_DONE { ok = false }
        }
        if reset {
            ok = exec("DELETE FROM events; DELETE FROM segments; DELETE FROM files; DELETE FROM sources; DELETE FROM fts;")
        }
        var known: [String: (Int64, Int64)] = [:]
        if ok, let st = prepare("SELECT name, bytes, lines FROM files") {
            var rc = sqlite3_step(st)
            while rc == SQLITE_ROW {
                known[text(st, 0) ?? ""] = (sqlite3_column_int64(st, 1), sqlite3_column_int64(st, 2))
                rc = sqlite3_step(st)
            }
            if rc != SQLITE_DONE { ok = false }
            sqlite3_finalize(st)
        } else { ok = false }
        let insE = prepare("INSERT OR REPLACE INTO events VALUES(?,?,?,?,?,?,?)")
        let insS = prepare("INSERT OR REPLACE INTO segments VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        let insSrc = prepare("INSERT OR IGNORE INTO sources VALUES(?,?,?,?,?,?)")
        let insF = prepare("INSERT INTO fts(text, kind, ts_ms, source, app, ref, file) VALUES(?,?,?,?,?,?,?)")
        let upF = prepare("INSERT OR REPLACE INTO files VALUES(?,?,?)")
        let del = [prepare("DELETE FROM events WHERE file=?"), prepare("DELETE FROM fts WHERE file=?")]
        defer { ([insE, insS, insSrc, insF, upF] + del).forEach { sqlite3_finalize($0) } }
        var added = 0
        let files = paths.dayFiles().map { ($0, paths.events + "/" + $0, false) }
            + paths.sourceFiles().map { ("sources/" + $0, paths.sources + "/" + $0, true) }
        for (name, path, isSource) in files where ok {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            var (offset, lines) = known[name] ?? (0, 0)
            if size == offset { continue }
            if size < offset {
                if !isSource { del.forEach { step($0, [name]) } }
                offset = 0; lines = 0
            }
            let res = readNew(path, offset: offset, lines: lines) { line, lineText in
                guard ok, let e = Event.parse(Substring(lineText)) else { return }
                if isSource {
                    guard let src = e.str("source"), let id = e.str("id") ?? e.int("id").map(String.init) else { return }
                    step(insSrc, [src, id, e.ts, Zone.day(e.ts), e.type, lineText])
                    guard ok, sqlite3_changes(db) > 0 else { return }
                    added += 1
                    let t = Index.sourceText(e)
                    if !t.isEmpty { step(insF, [t, "source", e.ts, src, nil, id, name]) }
                    return
                }
                step(insE, [name, line, e.ts, Zone.day(e.ts), e.type, e.str("seg"), lineText])
                added += 1
                if let (kind, t) = Index.searchable(e) { step(insF, [t, kind, e.ts, "act", e.str("bundle") ?? e.str("app"), e.str("seg"), name]) }
                if e.type == "segment.end" {
                    // A later record for the same (seg, part) — e.g. `revised: true` — replaces the earlier one.
                    let s = Seg(e)
                    step(insS, [s.seg, s.part, s.startMs, s.endMs, Zone.day(s.startMs), s.app, s.bundle, s.title, s.doc, s.url, s.host,
                                s.dur, s.active, s.idle, s.glance, s.reason, lineText])
                }
            }
            guard let (newOffset, newLines) = res else { continue }
            step(upF, [name, newOffset, newLines])
        }
        if ok && exec("COMMIT") { return added }
        exec("ROLLBACK")
        return nil
    }

    /// Drops everything and rebuilds from JSONL, in one transaction. Idempotent.
    @discardableResult
    public func reindex() -> Int? { ingest(reset: true) }

    public func segments(from: Int64, to: Int64) -> [Seg] {
        guard let st = prepare("SELECT json FROM segments WHERE start_ms >= ? AND start_ms < ? ORDER BY start_ms, part") else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, [from, to])
        var res: [Seg] = []
        while sqlite3_step(st) == SQLITE_ROW {
            if let t = text(st, 0), let e = Event.parse(Substring(t)) { res.append(Seg(e)) }
        }
        return res
    }

    /// Raw events ordered by ts. Filters are optional.
    public func events(from: Int64? = nil, to: Int64? = nil, typePrefix: String? = nil, seg: String? = nil, limit: Int = 500) -> [Event] {
        var sql = "SELECT json FROM events WHERE 1=1"
        var vals: [Any?] = []
        if let from { sql += " AND ts_ms >= ?"; vals.append(from) }
        if let to { sql += " AND ts_ms < ?"; vals.append(to) }
        if let typePrefix { sql += " AND type LIKE ?"; vals.append(typePrefix + "%") }
        if let seg { sql += " AND seg = ?"; vals.append(seg) }
        sql += " ORDER BY ts_ms, file, line LIMIT ?"; vals.append(limit)
        guard let st = prepare(sql) else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, vals)
        var res: [Event] = []
        while sqlite3_step(st) == SQLITE_ROW {
            if let t = text(st, 0), let e = Event.parse(Substring(t)) { res.append(e) }
        }
        return res
    }

    /// External source records ordered by ts.
    public func sourceEvents(from: Int64? = nil, to: Int64? = nil, source: String? = nil, typePrefix: String? = nil, limit: Int = 500) -> [Event] {
        var sql = "SELECT json FROM sources WHERE 1=1"
        var vals: [Any?] = []
        if let from { sql += " AND ts_ms >= ?"; vals.append(from) }
        if let to { sql += " AND ts_ms < ?"; vals.append(to) }
        if let source { sql += " AND source = ?"; vals.append(source) }
        if let typePrefix { sql += " AND type LIKE ?"; vals.append(typePrefix + "%") }
        sql += " ORDER BY ts_ms, source, id LIMIT ?"; vals.append(limit)
        guard let st = prepare(sql) else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, vals)
        var res: [Event] = []
        while sqlite3_step(st) == SQLITE_ROW {
            if let t = text(st, 0), let e = Event.parse(Substring(t)) { res.append(e) }
        }
        return res
    }

    public struct Hit { public var kind: String; public var ts: Int64; public var source: String; public var app: String?; public var ref: String?; public var text: String }

    /// Full-text search (trigram FTS5, any language). All whitespace-separated terms must match.
    /// Terms of 3+ characters use the index; shorter ones (e.g. 2-character Chinese words) fall back to LIKE.
    /// `source`: an external source name, or "act" for the recorder's own records. Newest first.
    public func search(_ query: String, from: Int64? = nil, to: Int64? = nil, source: String? = nil, limit: Int = 50) -> [Hit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var sql = "SELECT kind, ts_ms, source, app, ref, text FROM fts WHERE 1=1"
        var vals: [Any?] = []
        let long = terms.filter { $0.count >= 3 }
        if !long.isEmpty {
            sql += " AND fts MATCH ?"
            vals.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " "))
        }
        for t in terms where t.count < 3 {
            sql += " AND text LIKE ? ESCAPE '\\'"
            vals.append("%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%")
        }
        if let from { sql += " AND ts_ms >= ?"; vals.append(from) }
        if let to { sql += " AND ts_ms < ?"; vals.append(to) }
        if let source { sql += " AND source = ?"; vals.append(source) }
        sql += " ORDER BY ts_ms DESC LIMIT ?"; vals.append(limit)
        guard let st = prepare(sql) else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, vals)
        var res: [Hit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            res.append(Hit(kind: text(st, 0) ?? "", ts: sqlite3_column_int64(st, 1), source: text(st, 2) ?? "",
                           app: text(st, 3), ref: text(st, 4), text: text(st, 5) ?? ""))
        }
        return res
    }

    /// Stable dump used by tests to prove rebuilds are identical.
    public func fingerprint() -> String {
        var out = ""
        for q in ["SELECT file||':'||line||':'||json FROM events ORDER BY file, line",
                  "SELECT seg||':'||part||':'||json FROM segments ORDER BY seg, part",
                  "SELECT name||':'||bytes||':'||lines FROM files ORDER BY name",
                  "SELECT source||':'||id||':'||json FROM sources ORDER BY source, id",
                  "SELECT kind||':'||ts_ms||':'||source||':'||ifnull(ref,'')||':'||text FROM fts ORDER BY ts_ms, kind, ref, text"] {
            guard let st = prepare(q) else { continue }
            while sqlite3_step(st) == SQLITE_ROW { out += (text(st, 0) ?? "") + "\n" }
            sqlite3_finalize(st)
        }
        return out
    }
}
