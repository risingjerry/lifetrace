import Foundation

/// Pure query logic over segments + raw events. Every result is an act.v1 JSON object.
public enum Query {
    public static let mergeGapMs: Int64 = 60_000
    public static let interruptionMaxS: Double = 120
    public static let deepFocusS: Double = 25 * 60

    static func r(_ v: Double) -> J { .d(v) }

    public static func segJ(_ s: Seg, open: Bool = false) -> J {
        var kv: [(String, J)] = [("seg", .s(s.seg))]
        if s.part != 1 { kv.append(("part", .i(Int64(s.part)))) }
        kv += [("start", .s(Zone.iso(s.startMs))), ("end", .s(Zone.iso(s.endMs))), ("dur_s", r(s.dur)), ("active_s", r(s.active)),
               ("idle_s", r(s.idle)), ("glance", .b(s.glance)), ("reason", .s(s.reason)),
               ("app", .opt(s.app)), ("bundle", .opt(s.bundle)), ("title", .opt(s.title)), ("host", .opt(s.host)),
               ("url", .opt(s.url)), ("url_src", .opt(s.urlSrc)), ("doc", .opt(s.doc))]
        if open { kv.append(("open", .b(true))) }
        return .o(kv.filter { !$0.1.isNull })
    }

    /// Merge key for the timeline: same app and same site/document.
    static func mergeKey(_ s: Seg) -> String { s.appKey + "|" + (s.host ?? s.doc ?? "") }

    static let awayWhy: [String: String] = [
        "presence.lock": "lock", "presence.sleep": "sleep", "presence.display_sleep": "display_sleep",
        "recorder.pause": "pause", "recorder.stop": "recorder_off",
    ]

    /// Gaps > 1 s between consecutive segments, labelled by the first presence/recorder event inside them.
    public static func gaps(_ segs: [Seg], events: [Event]) -> [(Int64, Int64, String)] {
        let s = segs.sorted { $0.startMs < $1.startMs }
        var res: [(Int64, Int64, String)] = []
        guard s.count > 1 else { return res }
        for i in 1..<s.count {
            let a = s[i - 1].endMs, b = s[i].startMs
            guard b - a > 1000 else { continue }
            let why = events.first { $0.ts >= a - 1000 && $0.ts <= b && awayWhy[$0.type] != nil }.flatMap { awayWhy[$0.type] } ?? "unknown"
            res.append((a, b, why))
        }
        return res
    }

    struct Block {
        var first: Seg
        var end: Int64
        var dur = 0.0, active = 0.0, idle = 0.0
        var segs: [String] = []
        var glances = 0
        var titleTime: [String: Double] = [:]
        var urlTime: [String: Double] = [:]
        var historyURLs: Set<String> = []
        var open = false
    }

    // MARK: joining external records onto segments

    static func titleCandidates(_ title: String) -> [(text: String, prefix: Bool)] {
        var t = title.trimmingCharacters(in: .whitespaces)
        var prefix = false
        for ell in ["…", "..."] where t.hasSuffix(ell) { t = String(t.dropLast(ell.count)).trimmingCharacters(in: .whitespaces); prefix = true }
        var out = [(t, prefix)]
        // Browser window titles often carry a profile ("name: Page") or app ("Page - Google Chrome") wrapper.
        if let r = t.range(of: ": "), t.distance(from: t.startIndex, to: r.lowerBound) <= 40 { out.append((String(t[r.upperBound...]), prefix)) }
        if let r = t.range(of: " - ", options: .backwards) { out.append((String(t[..<r.lowerBound]), false)) }
        return out.filter { $0.0.count >= 2 }
    }

    static func titleMatches(_ visit: String, _ cands: [(text: String, prefix: Bool)]) -> Bool {
        cands.contains { c in c.prefix ? visit.hasPrefix(c.text) : (visit == c.text || (visit.count >= 4 && c.text.contains(visit))) }
    }

    public static let historyLookbackMs: Int64 = 12 * 3_600_000

    /// Browser segments with no live URL (Chromium browsers rarely expose it) get one from browser history
    /// records (`source.browser.visit`, field `browser` = app name): the latest visit up to the segment end
    /// whose title matches the window title (within `historyLookbackMs`), else the latest visit inside the segment.
    /// Filled-in segments carry `urlSrc = "history"`.
    struct Visit { let ts: Int64; let url: String; let title: String }

    public static func backfillURLs(_ segs: [Seg], sources: [Event]) -> [Seg] {
        var byBrowser: [String: [Visit]] = [:]
        for e in sources where e.type == "source.browser.visit" {
            guard let b = e.str("browser"), let u = e.str("url") else { continue }
            byBrowser[b, default: []].append(Visit(ts: e.ts, url: u, title: e.str("title") ?? ""))
        }
        guard !byBrowser.isEmpty else { return segs }
        for k in Array(byBrowser.keys) { byBrowser[k]!.sort { $0.ts < $1.ts } }
        var out = segs
        for i in out.indices {
            let s = out[i]
            guard s.url == nil, let app = s.app, let visits = byBrowser[app], let h = historyVisit(s, visits) else { continue }
            out[i].url = h.url
            out[i].urlSrc = "history"
            out[i].host = FocusCtx(url: h.url).host
        }
        return out
    }

    static func historyVisit(_ s: Seg, _ visits: [Visit]) -> Visit? {
        let cands: [(text: String, prefix: Bool)] = s.title.map { titleCandidates($0) } ?? []
        if !cands.isEmpty {
            for v in visits.reversed() where v.ts <= s.endMs {
                if v.ts < s.startMs - historyLookbackMs { break }
                if !v.title.isEmpty && titleMatches(v.title, cands) { return v }
            }
        }
        return visits.last { (v: Visit) -> Bool in v.ts >= s.startMs && v.ts <= s.endMs }
    }

    /// Chat records (any source record with `chat_name`, e.g. a messenger reader) that happened during a focus
    /// block of the app they come from (block app name contains the source name, case-insensitive).
    static func chats(_ app: String?, _ from: Int64, _ to: Int64, _ sources: [Event]) -> J? {
        guard let app = app?.lowercased() else { return nil }
        var agg: [String: (inC: Int, outC: Int, first: Int64)] = [:]
        for e in sources where e.ts >= from && e.ts <= to {
            guard let name = e.str("chat_name"), let src = e.str("source"), !src.isEmpty, app.contains(src.lowercased()) else { continue }
            var a = agg[name] ?? (0, 0, e.ts)
            if e.str("direction") == "out" { a.outC += 1 } else { a.inC += 1 }
            agg[name] = a
        }
        guard !agg.isEmpty else { return nil }
        let rows = agg.sorted { ($0.value.inC + $0.value.outC, -$0.value.first) > ($1.value.inC + $1.value.outC, -$1.value.first) }.prefix(8)
        return .a(rows.map { .o([("chat", .s($0.key)), ("in", .i(Int64($0.value.inC))), ("out", .i(Int64($0.value.outC)))]) })
    }

    public static func timeline(day: String, segs: [Seg], events: [Event], openSegs: Set<String> = [], raw: Bool = false,
                                sources: [Event] = []) -> J {
        let all = backfillURLs(segs, sources: sources).sorted { $0.startMs < $1.startMs }
        var items: [(Int64, J)] = []
        if raw {
            items = all.map { ($0.startMs, segJ($0, open: openSegs.contains($0.seg))) }
        } else {
            var blocks: [Block] = []
            var pendingGlances = 0
            for s in all {
                if s.glance { pendingGlances += 1; continue }
                if var b = blocks.last, mergeKey(b.first) == mergeKey(s), s.startMs - b.end <= mergeGapMs {
                    b.end = s.endMs; b.glances += pendingGlances
                    add(&b, s, openSegs); blocks[blocks.count - 1] = b
                } else {
                    if pendingGlances > 0, !blocks.isEmpty { blocks[blocks.count - 1].glances += pendingGlances }
                    var b = Block(first: s, end: s.endMs)
                    add(&b, s, openSegs); blocks.append(b)
                }
                pendingGlances = 0
            }
            if pendingGlances > 0, !blocks.isEmpty { blocks[blocks.count - 1].glances += pendingGlances }
            for b in blocks {
                let title = b.titleTime.max { $0.value < $1.value }?.key
                let url = b.urlTime.max { $0.value < $1.value }?.key
                var kv: [(String, J)] = [("kind", .s("focus")), ("start", .s(Zone.iso(b.first.startMs))), ("end", .s(Zone.iso(b.end))),
                    ("dur_s", r(b.dur)), ("active_s", r(b.active)), ("idle_s", r(b.idle)),
                    ("app", .opt(b.first.app)), ("bundle", .opt(b.first.bundle)), ("title", .opt(title)),
                    ("host", .opt(b.first.host)), ("url", .opt(url)), ("doc", .opt(b.first.doc)),
                    ("segs", .a(b.segs.map { .s($0) })), ("glances", .i(Int64(b.glances)))]
                if let url, b.historyURLs.contains(url), let i = kv.firstIndex(where: { $0.0 == "url" }) { kv.insert(("url_src", .s("history")), at: i + 1) }
                if let c = chats(b.first.app, b.first.startMs, b.end, sources) { kv.append(("chats", c)) }
                if b.open { kv.append(("open", .b(true))) }
                items.append((b.first.startMs, .o(kv.filter { !$0.1.isNull })))
            }
        }
        for (a, b, why) in gaps(all, events: events) {
            items.append((a, .o([("kind", .s("away")), ("start", .s(Zone.iso(a))), ("end", .s(Zone.iso(b))),
                                 ("dur_s", r(Double(b - a) / 1000)), ("why", .s(why))])))
        }
        items.sort { $0.0 < $1.0 }
        let totals = summary(all)
        return .o([("v", .s(schemaVersion)), ("query", .s("timeline")), ("day", .s(day)), ("tz", .s(Zone.suffix)),
                   ("merged", .b(!raw)), ("totals", totals), ("items", .a(items.map(\.1)))])
    }

    static func add(_ b: inout Block, _ s: Seg, _ openSegs: Set<String>) {
        b.dur += s.dur; b.active += s.active; b.idle += s.idle
        if b.segs.last != s.seg { b.segs.append(s.seg) }
        if let t = s.title { b.titleTime[t, default: 0] += max(s.dur, 0.001) }
        if let u = s.url { b.urlTime[u, default: 0] += max(s.dur, 0.001); if s.urlSrc != nil { b.historyURLs.insert(u) } }
        if openSegs.contains(s.seg) { b.open = true }
    }

    static func summary(_ segs: [Seg]) -> J {
        let dur = segs.reduce(0) { $0 + $1.dur }, act = segs.reduce(0) { $0 + $1.active }, idle = segs.reduce(0) { $0 + $1.idle }
        return .o([("tracked_s", r(dur)), ("active_s", r(act)), ("idle_s", r(idle)),
                   ("segments", .i(Int64(segs.count))), ("glances", .i(Int64(segs.filter(\.glance).count)))])
    }

    struct Agg { var label: [(String, J)]; var dur = 0.0; var active = 0.0; var n = 0 }

    static func top(_ m: [String: Agg], _ n: Int, totalActive: Double) -> J {
        .a(m.values.sorted { ($0.active, $0.dur) > ($1.active, $1.dur) }.prefix(n).map {
            .o($0.label.filter { !$0.1.isNull } + [("dur_s", r($0.dur)), ("active_s", r($0.active)), ("segments", .i(Int64($0.n))),
                                ("share", r(totalActive > 0 ? $0.active / totalActive : 0))])
        })
    }

    public static func stats(days: [String], segs: [Seg], top n: Int = 15) -> J {
        let all = segs.sorted { $0.startMs < $1.startMs }
        let totalActive = all.reduce(0) { $0 + $1.active }
        var byApp: [String: Agg] = [:], byHost: [String: Agg] = [:], byWin: [String: Agg] = [:]
        var hours = [Double](repeating: 0, count: 24)
        var perDay: [String: Double] = [:]
        for s in all {
            func bump(_ m: inout [String: Agg], _ k: String, _ label: [(String, J)]) {
                var a = m[k] ?? Agg(label: label); a.dur += s.dur; a.active += s.active; a.n += 1; m[k] = a
            }
            bump(&byApp, s.appKey, [("app", .opt(s.app)), ("bundle", .opt(s.bundle))])
            if let h = s.host { bump(&byHost, h, [("host", .s(h))]) }
            if let t = s.title { bump(&byWin, s.appKey + "|" + t, [("app", .opt(s.app)), ("title", .s(t))]) }
            perDay[Zone.day(s.startMs), default: 0] += s.active
            // Spread active time over local clock hours proportionally to wall time.
            if s.dur > 0 {
                var t = s.startMs
                while t < s.endMs {
                    let hourEnd = (t + Zone.offsetMs) / 3_600_000 * 3_600_000 + 3_600_000 - Zone.offsetMs
                    let z = min(hourEnd, s.endMs)
                    let h = Int(((t + Zone.offsetMs) / 3_600_000) % 24)
                    hours[h] += s.active * Double(z - t) / 1000 / s.dur
                    t = z
                }
            }
        }
        // Switches, interruptions and focus streaks look at non-glance segments only.
        let real = all.filter { !$0.glance }
        var switches = 0
        for (a, b) in zip(all, all.dropFirst()) where a.appKey != b.appKey { switches += 1 }
        var interruptions = 0
        if real.count >= 3 {
            for i in 1..<(real.count - 1) {
                let a = real[i - 1], b = real[i], c = real[i + 1]
                if a.appKey == c.appKey, b.appKey != a.appKey, b.dur <= interruptionMaxS { interruptions += 1 }
            }
        }
        var streaks: [(Seg, Int64, Double, Double)] = []   // first, end, active, dur
        for s in real {
            if var cur = streaks.last, cur.0.appKey == s.appKey, s.startMs - cur.1 <= mergeGapMs {
                cur.1 = s.endMs; cur.2 += s.active; cur.3 += s.dur; streaks[streaks.count - 1] = cur
            } else {
                streaks.append((s, s.endMs, s.active, s.dur))
            }
        }
        let best = streaks.max { $0.2 < $1.2 }
        let longest: J = best.map { b in
            .o([("app", .opt(b.0.app)), ("bundle", .opt(b.0.bundle)), ("start", .s(Zone.iso(b.0.startMs))), ("end", .s(Zone.iso(b.1))),
                ("active_s", r(b.2)), ("dur_s", r(b.3))].filter { !$0.1.isNull })
        } ?? .null
        var kv: [(String, J)] = [("v", .s(schemaVersion)), ("query", .s("stats")), ("tz", .s(Zone.suffix)),
            ("from", .s(days.first ?? "")), ("to", .s(days.last ?? "")), ("totals", summary(all)),
            ("app_switches", .i(Int64(switches))), ("interruptions", .i(Int64(interruptions))),
            ("longest_focus", longest), ("deep_focus_blocks", .i(Int64(streaks.filter { $0.2 >= deepFocusS }.count))),
            ("by_app", top(byApp, n, totalActive: totalActive)), ("by_domain", top(byHost, n, totalActive: totalActive)),
            ("by_window", top(byWin, n, totalActive: totalActive)),
            ("active_by_hour", .a(hours.map { r($0) }))]
        if days.count > 1 { kv.append(("active_by_day", .a(days.map { .o([("day", .s($0)), ("active_s", r(perDay[$0] ?? 0))]) }))) }
        return .o(kv)
    }

    /// One-line human summary of an external source record: the first of the usual text fields.
    public static func sourceSummary(_ e: Event) -> String {
        let keys = ["title", "name", "subject", "summary", "text", "body", "content", "query", "url", "path"]
        let s = keys.lazy.compactMap { e.str($0) }.first { !$0.isEmpty } ?? e.type
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    /// Adds external source records to a timeline as `{kind:"source", ts, source, type, id, summary}` items.
    public static func interleave(_ timeline: J, _ sources: [Event]) -> J {
        guard case .o(var kv) = timeline, case .a(let items)? = timeline["items"] else { return timeline }
        var all: [(String, J)] = items.map { ($0["start"]?.str ?? "", $0) }
        for e in sources {
            all.append((Zone.iso(e.ts), .o([("kind", .s("source")), ("ts", .s(Zone.iso(e.ts))), ("source", .opt(e.str("source"))),
                                          ("type", .s(e.type)), ("id", .opt(e.str("id"))), ("summary", .s(sourceSummary(e)))])))
        }
        // ISO strings with the same offset sort chronologically.
        let merged = all.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        if let i = kv.firstIndex(where: { $0.0 == "items" }) { kv[i].1 = .a(merged) }
        kv.append(("sources", .i(Int64(sources.count))))
        return .o(kv)
    }

    public static func searchResult(_ q: String, _ hits: [Index.Hit]) -> J {
        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        return .o([("v", .s(schemaVersion)), ("query", .s("search")), ("q", .s(q)), ("count", .i(Int64(hits.count))),
                   ("hits", .a(hits.map { h in
                       var kv: [(String, J)] = [("ts", .s(Zone.iso(h.ts))), ("kind", .s(h.kind)), ("source", .s(h.source)), ("app", .opt(h.app))]
                       kv.append(h.source == "act" ? ("seg", .opt(h.ref)) : ("id", .opt(h.ref)))
                       kv.append(("snippet", .s(snippet(h.text, terms))))
                       return .o(kv.filter { !$0.1.isNull })
                   }))])
    }

    /// About 160 characters around the first matching term, on one line.
    public static func snippet(_ text: String, _ terms: [String], width: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = terms.lazy.compactMap({ flat.range(of: $0, options: .caseInsensitive) }).first else {
            return flat.count > width ? String(flat.prefix(width)) + "…" : flat
        }
        let pos = flat.distance(from: flat.startIndex, to: r.lowerBound)
        let a = max(0, pos - width / 3)
        let start = flat.index(flat.startIndex, offsetBy: a)
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (a > 0 ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    public static func at(_ t: Int64, segs: [Seg], events: [Event], openSegs: Set<String> = [], sources: [Event] = []) -> J {
        let all = segs.sorted { $0.startMs < $1.startMs }
        let hit = all.last { $0.startMs <= t && t < $0.endMs }
        var state = "unknown", why: String? = nil
        if hit != nil {
            let idle = events.last { $0.ts <= t && ($0.type == "presence.idle_start" || $0.type == "presence.idle_end") }
            state = idle?.type == "presence.idle_start" ? "idle" : "active"
        } else if let last = events.last(where: { $0.ts <= t && (Query.awayWhy[$0.type] != nil || Segmenter.awayEnd[$0.type] != nil || $0.type == "recorder.start") }),
                  let w = Query.awayWhy[last.type] {
            state = "away"; why = w
        }
        let prev = all.last { $0.endMs <= t }
        let next = all.first { $0.startMs > t }
        // Own events and external source records within ±2 min, interleaved by time.
        let near = (events.filter { abs($0.ts - t) <= 120_000 && $0.type != "segment.end" } + sources.filter { abs($0.ts - t) <= 120_000 })
            .enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
        var kv: [(String, J)] = [("v", .s(schemaVersion)), ("query", .s("at")), ("at", .s(Zone.iso(t))), ("state", .s(state))]
        if let why { kv.append(("why", .s(why))) }
        kv += [("segment", hit.map { segJ($0, open: openSegs.contains($0.seg)) } ?? .null),
               ("prev", prev.map { segJ($0) } ?? .null), ("next", next.map { segJ($0, open: openSegs.contains($0.seg)) } ?? .null),
               ("events", .a(near.map(\.json)))]
        return .o(kv)
    }
}
