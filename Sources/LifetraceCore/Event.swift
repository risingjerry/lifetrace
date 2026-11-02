import Foundation

public let schemaVersion = "act.v1"
public let lifetraceVersion = "0.3.0"

/// One act.v1 record. `ts` is epoch milliseconds; it is written as ISO 8601 in the configured UTC offset (`Zone`).
public struct Event {
    public var ts: Int64
    public var type: String
    /// Payload fields in output order (excluding v, ts, type). Null values are dropped on write.
    public var fields: [(String, J)]

    public init(ts: Int64, type: String, _ fields: [(String, J)] = []) {
        self.ts = ts; self.type = type; self.fields = fields
    }

    public subscript(_ key: String) -> J? {
        get { fields.first(where: { $0.0 == key })?.1 }
        set {
            if let i = fields.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { fields[i].1 = v } else { fields.remove(at: i) }
            } else if let v = newValue { fields.append((key, v)) }
        }
    }

    public func str(_ k: String) -> String? { self[k]?.str }
    public func int(_ k: String) -> Int64? { self[k]?.int }

    public var json: J {
        .o([("v", .s(schemaVersion)), ("ts", .s(Zone.iso(ts))), ("type", .s(type))] + fields.filter { !$0.1.isNull })
    }

    public func line() -> String { json.encode() }

    /// Parses one JSONL line. Returns nil for blank/corrupt lines or foreign schema versions.
    public static func parse(_ line: Substring) -> Event? {
        guard !line.isEmpty, let j = J.parse(String(line)), case .o(let kv) = j,
              j["v"]?.str == schemaVersion, let tsS = j["ts"]?.str, let ts = Zone.parse(tsS),
              let type = j["type"]?.str else { return nil }
        return Event(ts: ts, type: type, kv.filter { !["v", "ts", "type"].contains($0.0) })
    }
}

/// What is in front of the user right now.
public struct FocusCtx: Equatable {
    public var app: String?
    public var bundle: String?
    public var pid: Int?
    public var win: Int?
    public var title: String?
    public var doc: String?
    public var url: String?

    public init(app: String? = nil, bundle: String? = nil, pid: Int? = nil, win: Int? = nil,
                title: String? = nil, doc: String? = nil, url: String? = nil) {
        self.app = app; self.bundle = bundle; self.pid = pid; self.win = win
        self.title = title; self.doc = doc; self.url = url
    }

    public var host: String? { url.flatMap { URLComponents(string: $0)?.host?.lowercased() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }

    /// URL without fragment: same page = same segment.
    public var urlKey: String { guard let url else { return "" }; return url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url }

    /// Segment identity: app + window + document/url. Title alone does not split a segment.
    public var key: String { "\(bundle ?? app ?? "?")|\(win.map(String.init) ?? "")|\(doc ?? "")|\(urlKey)" }

    public var fields: [(String, J)] {
        [("app", .opt(app)), ("bundle", .opt(bundle)), ("pid", .opt(pid)), ("win", .opt(win)),
         ("title", .opt(title)), ("doc", .opt(doc)), ("url", .opt(url)), ("host", .opt(host))]
    }

    public init(event e: Event) {
        self.init(app: e.str("app"), bundle: e.str("bundle"), pid: e.int("pid").map { Int($0) },
                  win: e.int("win").map { Int($0) }, title: e.str("title"), doc: e.str("doc"), url: e.str("url"))
    }

    /// The context with credentials masked in title, document path and URL (applied before anything is written).
    public func redacted() -> FocusCtx {
        var c = self
        c.title = title.map(Redact.apply); c.doc = doc.map(Redact.apply); c.url = url.map(Redact.url)
        return c
    }

    /// Strips terminal spinner glyphs (Braille, ✳ etc.) that some apps animate in window titles.
    public static func normalizeTitle(_ raw: String?) -> String? {
        guard var t = raw else { return nil }
        let spin: Set<Character> = ["✳", "✶", "✻", "✽", "✢", "·", "*", "●", "○", "◐", "◓", "◑", "◒"]
        while let c = t.first, c.isWhitespace || spin.contains(c) || (c.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false) {
            t.removeFirst()
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
