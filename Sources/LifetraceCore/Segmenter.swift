import Foundation

/// Pure state machine: raw act.v1 events in, `segment.end` records out.
/// The daemon feeds it live; queries and crash recovery replay the log through it.
public final class Segmenter {
    public static let awayStart: [String: String] = [
        "presence.lock": "lock", "presence.sleep": "sleep", "presence.display_sleep": "display",
        "recorder.pause": "pause", "recorder.stop": "stop",
    ]
    public static let awayEnd: [String: String] = [
        "presence.unlock": "lock", "presence.wake": "sleep", "presence.display_wake": "display",
        "recorder.resume": "pause",
    ]

    struct Open {
        var seg: String
        var start: Int64
        var ctx: FocusCtx
        var idle: [(Int64, Int64?)]
        /// Distinct titles, kept as in-memory hashes and bounded (a terminal can retitle itself forever).
        var titles: Set<Int>
        var titlesCapped = false
        var input: InputCounts?

        init(seg: String, start: Int64, ctx: FocusCtx, idle: [(Int64, Int64?)], title: String?) {
            self.seg = seg; self.start = start; self.ctx = ctx; self.idle = idle
            titles = []; addTitle(title)
        }

        mutating func addTitle(_ t: String?) {
            guard let t else { return }
            if titles.count < Segmenter.maxTitles { titles.insert(t.hashValue) }
            else if !titles.contains(t.hashValue) { titlesCapped = true }
        }
    }

    static let maxTitles = 256, maxClosed = 16

    /// Segments closed by a focus change while no input has been seen since. Idle is detected only
    /// `idle_threshold_s` after the last input and back-dated to it, so such a segment may turn out to have
    /// ended inside an idle period; it is then written again with the idle part (`revised: true`).
    var closed: [(o: Open, end: Int64, reason: String)] = []

    public let glanceMs: Int64
    public private(set) var ctx: FocusCtx?
    public private(set) var away: Set<String> = []
    public private(set) var idleSince: Int64?
    var open: Open?
    var lastSegTs: Int64 = .min

    /// When replaying the log (queries, crash recovery) there is no live input; `activity.minute`
    /// records stand in for it and are added to the segment open at the time they were written.
    public var replayInput = false

    public init(glanceS: Double = 2) { glanceMs = Int64(glanceS * 1000) }

    public var openSeg: String? { open?.seg }

    /// Live input counts for the open segment (the daemon calls this before feeding each event).
    public func addInput(_ c: InputCounts) {
        // Live input after the last fed event: no later idle period can reach back into closed segments.
        if !c.isZero && !replayInput { closed.removeAll() }
        guard var o = open else { return }
        o.input = (o.input ?? InputCounts()) + c
        open = o
    }

    /// Returns the records to write, in order: any `segment.end` produced, then `e` itself
    /// (annotated with `seg` when it is a focus event that belongs to a segment).
    public func feed(_ input: Event) -> [Event] {
        var e = input
        var out: [Event] = []
        let t = e.type
        if t == "segment.end" { return [] }
        if t == "recorder.start" {
            open = nil; ctx = nil; away = []; idleSince = nil; closed = []
            return [e]
        }
        if t.hasPrefix("focus.") {
            var c = ctx ?? FocusCtx()
            let n = FocusCtx(event: e)
            if t == "focus.app" { c = n } else {
                if n.app != nil { c.app = n.app }
                if n.bundle != nil { c.bundle = n.bundle }
                if n.pid != nil { c.pid = n.pid }
                c.win = n.win; c.title = n.title; c.doc = n.doc; c.url = n.url
            }
            ctx = c
            guard away.isEmpty else { return [e] }
            if var o = open {
                if o.ctx.key == c.key {
                    o.addTitle(c.title)
                    o.ctx = c
                    open = o
                    e["seg"] = .s(o.seg)
                    return [e]
                }
                out += close(at: e.ts, reason: reason(old: o.ctx, new: c))
            }
            let seg = e.str("seg") ?? newSeg(e.ts)
            open = Open(seg: seg, start: e.ts, ctx: c, idle: idleSince.map { [($0 < e.ts ? e.ts : $0, nil)] } ?? [],
                        title: c.title)
            e["seg"] = .s(seg)
            return out + [e]
        }
        if t.hasPrefix("content.") || t.hasPrefix("activity.") {
            if let o = open, e["seg"] == nil { e["seg"] = .s(o.seg) }
            if t == "activity.minute", replayInput, e.str("seg") == open?.seg { addInput(InputCounts(event: e)) }
            return [e]
        }
        switch t {
        case "presence.idle_start":
            idleSince = e.ts
            out += revise(idleFrom: e.ts)
            if var o = open, o.idle.last.map({ $0.1 != nil }) ?? true {
                o.idle.append((max(e.ts, o.start), nil)); open = o
            }
        case "presence.idle_end":
            idleSince = nil
            if var o = open, let last = o.idle.last, last.1 == nil {
                o.idle[o.idle.count - 1].1 = max(e.ts, last.0); open = o
            }
        default:
            if let why = Segmenter.awayStart[t] {
                if open != nil { out += close(at: e.ts, reason: e.str("reason") == "crash" ? "crash" : why) }
                away.insert(why); idleSince = nil; closed = []
            } else if let why = Segmenter.awayEnd[t] {
                away.remove(why)
                if why == "sleep" { away.remove("display") }
            }
        }
        return out + [e]
    }

    /// The still-open segment as it would look if it ended at `now` (does not mutate state).
    public func peekOpen(at now: Int64) -> [Event] {
        guard let o = open else { return [] }
        return pieces(o, end: now, reason: "open")
    }

    func reason(old: FocusCtx, new: FocusCtx) -> String {
        if (old.bundle ?? old.app) != (new.bundle ?? new.app) { return "switch" }
        if old.win != new.win { return "window" }
        if old.doc != new.doc { return "doc" }
        return "url"
    }

    func newSeg(_ ts: Int64) -> String {
        let t = ts > lastSegTs ? ts : lastSegTs + 1
        lastSegTs = t
        return "s" + String(t, radix: 36)
    }

    func close(at end: Int64, reason: String) -> [Event] {
        guard let o = open else { return [] }
        open = nil
        if ["switch", "window", "doc", "url"].contains(reason) {
            closed.append((o, end, reason))
            if closed.count > Segmenter.maxClosed { closed.removeFirst() }
        }
        return pieces(o, end: end, reason: reason)
    }

    /// Re-emits recently closed segments that ended after `from` (a back-dated idle start) with that idle added.
    func revise(idleFrom from: Int64) -> [Event] {
        defer { closed = [] }
        var res: [Event] = []
        for var c in closed where c.end > max(from, c.o.start) && c.o.idle.allSatisfy({ $0.1 != nil }) {
            c.o.idle.append((max(from, c.o.start), c.end))
            res += pieces(c.o, end: c.end, reason: c.reason, revised: true)
        }
        return res
    }

    /// Builds `segment.end` records, one per local day the segment touches.
    func pieces(_ o: Open, end rawEnd: Int64, reason: String, revised: Bool = false) -> [Event] {
        let end = max(rawEnd, o.start)
        let idle = o.idle.map { (max($0.0, o.start), min($0.1 ?? end, end)) }.filter { $0.1 > $0.0 }
        var cuts: [Int64] = [o.start]
        var b = (Zone.dayStart(Zone.day(o.start)) ?? o.start) + Zone.dayMs
        while b < end { cuts.append(b); b += Zone.dayMs }
        cuts.append(end)
        let parts = cuts.count - 1
        let glance = end - o.start < glanceMs
        var res: [Event] = []
        for p in 0..<parts {
            let a = cuts[p], z = cuts[p + 1]
            let idleMs = idle.reduce(Int64(0)) { $0 + max(0, min($1.1, z) - max($1.0, a)) }
            let durMs = z - a
            var f: [(String, J)] = [("seg", .s(o.seg))]
            if parts > 1 { f += [("part", .i(Int64(p + 1))), ("parts", .i(Int64(parts)))] }
            f += [("start", .s(Zone.iso(a))), ("end", .s(Zone.iso(z))),
                  ("dur_s", .d(Double(durMs) / 1000)), ("active_s", .d(Double(durMs - idleMs) / 1000)),
                  ("idle_s", .d(Double(idleMs) / 1000)), ("glance", .b(glance)), ("reason", .s(p == parts - 1 ? reason : "midnight")),
                  ("titles", .i(Int64(o.titles.count)))]
            if o.titlesCapped { f.append(("titles_capped", .b(true))) }
            if revised { f.append(("revised", .b(true))) }
            f += o.ctx.fields
            // Input counts are not split by time: all of them go on the last piece.
            if p == parts - 1, let c = o.input { f += c.fields }
            // A non-empty piece that ends exactly at midnight is filed under the day it covers.
            res.append(Event(ts: z > a && Zone.day(z) != Zone.day(a) ? z - 1 : z, type: "segment.end", f))
        }
        return res
    }
}
