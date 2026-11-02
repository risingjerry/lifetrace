import XCTest
@testable import LifetraceCore
import SQLite3

/// Fixtures are written for UTC+08:00; pin it so results never depend on the test machine's zone.
class PinnedZoneCase: XCTestCase {
    override class func setUp() { super.setUp(); Zone.configure("+08:00") }
}

/// 2026-11-01 10:00:00.000 at UTC+08:00 as epoch ms.
let T0 = Zone.parse("2026-11-01T10:00:00.000+08:00")!
func at(_ s: Double) -> Int64 { T0 + Int64(s * 1000) }
func ev(_ s: Double, _ type: String, _ f: [(String, J)] = []) -> Event { Event(ts: at(s), type: type, f) }
func app(_ s: Double, _ bundle: String, win: Int? = nil, title: String? = nil, url: String? = nil, doc: String? = nil) -> Event {
    ev(s, "focus.app", FocusCtx(app: bundle, bundle: bundle, pid: 1, win: win, title: title, doc: doc, url: url).fields)
}
func feedAll(_ evs: [Event], glance: Double = 2) -> (Segmenter, [Event]) {
    let s = Segmenter(glanceS: glance)
    var outs: [Event] = []
    for e in evs { outs += s.feed(e) }
    return (s, outs.filter { $0.type == "segment.end" })
}

final class TimeTests: PinnedZoneCase {
    func testISOAndDay() {
        XCTAssertEqual(Zone.iso(0), "1970-01-01T08:00:00.000+08:00")
        XCTAssertEqual(Zone.iso(T0 + 123), "2026-11-01T10:00:00.123+08:00")
        // 2026-11-01 15:59:59.999Z is 23:59:59.999 at +08:00 -> still Nov 1; one ms later is Nov 2.
        let edge = Zone.parse("2026-11-01T15:59:59.999Z")!
        XCTAssertEqual(Zone.day(edge), "2026-11-01")
        XCTAssertEqual(Zone.day(edge + 1), "2026-11-02")
        XCTAssertEqual(Zone.dayStart("2026-11-02"), edge + 1)
        XCTAssertEqual(Zone.addDays("2026-12-31", 1), "2027-01-01")
    }

    func testParseForms() {
        XCTAssertEqual(Zone.parse("2026-11-01 10:00"), T0)
        XCTAssertEqual(Zone.parse("2026-11-01T02:00:00Z"), T0)
        XCTAssertEqual(Zone.parse("2026-10-31T22:00:00-04:00"), T0)  // New York EDT wall time -> same instant
        XCTAssertEqual(Zone.parse("10:00:00", onDay: "2026-11-01"), T0)
        XCTAssertEqual(Zone.parse(Zone.iso(T0 + 4567)), T0 + 4567)
    }

    func testConfiguredOffset() {
        XCTAssertEqual(Zone.parseOffset("+08:00"), 8 * 3_600_000)
        XCTAssertEqual(Zone.parseOffset("-05:30"), -(5 * 3_600_000 + 30 * 60_000))
        XCTAssertEqual(Zone.parseOffset("Z"), 0)
        for bad in ["8", "+8:00", "+25:00", "Asia/Shanghai", ""] { XCTAssertNil(Zone.parseOffset(bad), bad) }
        defer { Zone.configure("+08:00") }
        XCTAssertFalse(Zone.configure(nil, "bogus"))
        XCTAssertEqual(Zone.suffix, "+08:00")
        XCTAssertTrue(Zone.configure("bogus", "-05:00"))
        XCTAssertEqual(Zone.suffix, "-05:00")
        XCTAssertEqual(Zone.iso(T0), "2026-10-31T21:00:00.000-05:00")
        XCTAssertEqual(Zone.day(T0), "2026-10-31")
        XCTAssertEqual(Zone.parse("2026-10-31 21:00"), T0)
    }
}

final class SegmenterTests: PinnedZoneCase {
    func testSwitchProducesSegmentWithDuration() {
        let (_, segs) = feedAll([ev(0, "recorder.start"), app(0, "a"), app(30, "b"), ev(40, "recorder.stop")])
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0]["dur_s"]?.dbl, 30)
        XCTAssertEqual(segs[0]["active_s"]?.dbl, 30)
        XCTAssertEqual(segs[0].str("reason"), "switch")
        XCTAssertEqual(segs[1]["dur_s"]?.dbl, 10)
        XCTAssertEqual(segs[1].str("reason"), "stop")
        XCTAssertEqual(segs[0].ts, at(30))
    }

    func testGlanceFlag() {
        let (_, segs) = feedAll([ev(0, "recorder.start"), app(0, "a"), app(10, "b"), app(11.5, "a"), app(20, "c")])
        XCTAssertEqual(segs.map { $0["glance"]?.bool }, [false, true, false])
        XCTAssertEqual(segs[1]["dur_s"]?.dbl, 1.5)
    }

    func testIdleMath() {
        // idle 20..50 inside a 0..100 segment
        let (_, segs) = feedAll([ev(0, "recorder.start"), app(0, "a"), ev(20, "presence.idle_start"), ev(50, "presence.idle_end"), app(100, "b")])
        XCTAssertEqual(segs[0]["dur_s"]?.dbl, 100)
        XCTAssertEqual(segs[0]["idle_s"]?.dbl, 30)
        XCTAssertEqual(segs[0]["active_s"]?.dbl, 70)
    }

    func testIdleSpanningSegments() {
        // idle starts in seg A, a title-less window change happens while idle, idle ends in seg B
        let (_, segs) = feedAll([ev(0, "recorder.start"), app(0, "a"), ev(10, "presence.idle_start"),
                             app(30, "b"), ev(45, "presence.idle_end"), app(60, "c")])
        XCTAssertEqual(segs[0]["idle_s"]?.dbl, 20)   // 10..30
        XCTAssertEqual(segs[1]["idle_s"]?.dbl, 15)   // 30..45
        XCTAssertEqual(segs[1]["active_s"]?.dbl, 15)
    }

    func testIdleStartBackdatedBeforeSegmentIsClamped() {
        let (_, all) = feedAll([ev(0, "recorder.start"), app(0, "a"), app(30, "b"), ev(10, "presence.idle_start"), app(60, "c")])
        let segs = all.filter { $0["revised"] == nil }
        XCTAssertEqual(segs[1]["idle_s"]?.dbl, 30)
        // no input since 10 s: the already closed "a" is written again with 10..30 idle
        XCTAssertEqual(all.filter { $0["revised"]?.bool == true }.map { $0["idle_s"]?.dbl }, [20])
    }

    func testTitleChangeKeepsSegmentButURLSplits() {
        let (s, segs) = feedAll([ev(0, "recorder.start"), app(0, "br", win: 1, title: "A", url: "https://x.com/a#top"),
                             ev(5, "focus.title", FocusCtx(app: "br", bundle: "br", pid: 1, win: 1, title: "A (1)", url: "https://x.com/a#c").fields),
                             ev(9, "focus.title", FocusCtx(app: "br", bundle: "br", pid: 1, win: 1, title: "B", url: "https://y.com/").fields),
                             ev(12, "focus.window", FocusCtx(app: "br", bundle: "br", pid: 1, win: 2, title: "B").fields),
                             ev(20, "recorder.stop")])
        XCTAssertEqual(segs.map { $0.str("reason") }, ["url", "window", "stop"])
        XCTAssertEqual(segs[0]["titles"]?.int, 2)
        XCTAssertEqual(segs[0].str("host"), "x.com")
        XCTAssertEqual(segs[1].str("host"), "y.com")
        XCTAssertNil(s.openSeg)
    }

    func testAwayClosesAndFocusReopens() {
        let (_, segs) = feedAll([ev(0, "recorder.start"), app(0, "a"), ev(10, "presence.lock"),
                             app(15, "b"),                       // while locked: context only, no segment
                             ev(100, "presence.unlock"), app(100, "a"), ev(130, "recorder.stop")])
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].str("reason"), "lock")
        XCTAssertEqual(segs[0]["dur_s"]?.dbl, 10)
        XCTAssertEqual(segs[1]["dur_s"]?.dbl, 30)
    }

    func testSleepWakeAndDisplay() {
        let (s, _) = feedAll([ev(0, "recorder.start"), app(0, "a"), ev(5, "presence.display_sleep"), ev(6, "presence.sleep"), ev(50, "presence.wake")])
        XCTAssertTrue(s.away.isEmpty)
    }

    func testMidnightSplit() {
        let late = Zone.parse("2026-11-01T23:59:00.000+08:00")!
        let s = Segmenter()
        _ = s.feed(Event(ts: late, type: "recorder.start"))
        _ = s.feed(Event(ts: late, type: "focus.app", FocusCtx(app: "a", bundle: "a").fields))
        _ = s.feed(Event(ts: late + 30_000, type: "presence.idle_start"))
        _ = s.feed(Event(ts: late + 90_000, type: "presence.idle_end"))     // idle 23:59:30 .. 00:00:30
        let segs = s.feed(Event(ts: late + 120_000, type: "focus.app", FocusCtx(app: "b", bundle: "b").fields)).filter { $0.type == "segment.end" }
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs.map { Zone.day($0.ts) }, ["2026-11-01", "2026-11-02"])
        XCTAssertEqual(segs[0]["dur_s"]?.dbl, 60); XCTAssertEqual(segs[0]["idle_s"]?.dbl, 30)
        XCTAssertEqual(segs[1]["dur_s"]?.dbl, 60); XCTAssertEqual(segs[1]["idle_s"]?.dbl, 30)
        XCTAssertEqual(segs[0].str("reason"), "midnight"); XCTAssertEqual(segs[1].str("reason"), "switch")
        XCTAssertEqual(segs[0].str("seg"), segs[1].str("seg"))
        XCTAssertEqual(segs[1].str("start"), "2026-11-02T00:00:00.000+08:00")
    }

    func testSpinnerTitleNormalized() {
        XCTAssertEqual(FocusCtx.normalizeTitle("⠋ claude: fix tests"), "claude: fix tests")
        XCTAssertEqual(FocusCtx.normalizeTitle("✳ Claude Code"), "Claude Code")
        XCTAssertNil(FocusCtx.normalizeTitle("  "))
    }

    func testPeekOpenDoesNotMutate() {
        let (s, _) = feedAll([ev(0, "recorder.start"), app(0, "a")])
        XCTAssertEqual(s.peekOpen(at: at(12)).first?["dur_s"]?.dbl, 12)
        XCTAssertNotNil(s.openSeg)
    }
}

final class StoreIndexTests: PinnedZoneCase {
    var dir = ""
    var paths: Paths!

    override func setUp() {
        dir = NSTemporaryDirectory() + "lifetrace-test-\(UUID().uuidString)"
        paths = Paths(home: dir, config: dir + "/none.json")
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ evs: [Event]) {
        let j = Journal(paths); let s = Segmenter()
        for e in evs { for o in s.feed(e) { j.append(o) } }
    }

    func testJournalFilesByBeijingDayAndCrashRecovery() {
        let late = Zone.parse("2026-11-01T23:59:50.000+08:00")!
        write([Event(ts: late, type: "recorder.start"), Event(ts: late, type: "focus.app", FocusCtx(app: "a", bundle: "a").fields),
               Event(ts: late + 20_000, type: "focus.app", FocusCtx(app: "b", bundle: "b").fields),
               Event(ts: late + 40_000, type: "presence.idle_start")])   // then "crash"
        XCTAssertEqual(paths.dayFiles(), ["2026-11-01.jsonl", "2026-11-02.jsonl"])
        let rec = Log.recovery(paths, glanceS: 2)
        XCTAssertEqual(rec.map(\.type), ["segment.end", "recorder.stop"])
        XCTAssertEqual(rec[0].str("app"), "b")
        XCTAssertEqual(rec[0]["dur_s"]?.dbl, 20)
        XCTAssertEqual(rec[0]["idle_s"]?.dbl, 0)
        XCTAssertEqual(rec[1].str("reason"), "crash")
        XCTAssertEqual(rec[0].str("reason"), "crash")
        // After a clean stop nothing to recover.
        let j = Journal(paths); for e in rec { j.append(e) }
        XCTAssertTrue(Log.recovery(paths, glanceS: 2).isEmpty)
    }

    func testReindexIdempotentAndIncrementalEqualsFull() throws {
        write([ev(0, "recorder.start"), app(0, "a"), app(30, "b"), ev(35, "presence.idle_start"), ev(80, "presence.idle_end")])
        let idx = try Index(paths)
        XCTAssertGreaterThan(idx.catchUp() ?? 0, 0)
        // more lines arrive, incremental catch-up
        let j = Journal(paths)
        let s = Log.replay(Log.sinceLastStart(paths), glanceS: 2)
        for e in [app(90, "a"), ev(100, "recorder.stop")] { for o in s.feed(e) { j.append(o) } }
        // a torn (half-written) line must not be indexed until complete
        let fh = FileHandle(forWritingAtPath: paths.dayFile("2026-11-01"))!
        fh.seekToEndOfFile(); fh.write("{\"v\":\"act.v1\",\"ts\":".data(using: .utf8)!); try fh.close()
        idx.catchUp()
        let incremental = idx.fingerprint()
        idx.reindex(); let full1 = idx.fingerprint()
        idx.reindex(); let full2 = idx.fingerprint()
        XCTAssertEqual(full1, full2)
        XCTAssertEqual(incremental, full1)
        let segs = idx.segments(from: T0, to: T0 + Zone.dayMs)
        XCTAssertEqual(segs.map(\.appKey), ["a", "b", "a"])
        XCTAssertEqual(segs[1].idle, 45)
        XCTAssertEqual(idx.events(seg: segs[0].seg).map(\.type), ["focus.app", "segment.end"])
    }
}

final class QueryTests: PinnedZoneCase {
    func segs(_ evs: [Event]) -> [Seg] { feedAll(evs).1.map { Seg($0) } }

    func testStatsSwitchesInterruptionsStreak() {
        let s = segs([ev(0, "recorder.start"), app(0, "code"), app(600, "chat"), app(660, "code"), app(1.0 + 660, "x"),
                      app(662, "code"), app(2400, "web", url: "https://www.github.com/a"), ev(2500, "recorder.stop")])
        let j = Query.stats(days: ["2026-11-01"], segs: s)
        XCTAssertEqual(j["app_switches"]?.int, 5)
        XCTAssertEqual(j["interruptions"]?.int, 1)        // code -> chat(60 s) -> code
        // streak: code 0..600, then (chat breaks it), code 660..2400 with a 1 s glance inside
        XCTAssertEqual(j["longest_focus"]?["app"]?.str, "code")
        XCTAssertEqual(j["longest_focus"]?["active_s"]?.dbl, 1738)  // 662..2400; the 1 s code glance is not counted
        if case .a(let d)? = j["by_domain"] { XCTAssertEqual(d.first?["host"]?.str, "github.com") } else { XCTFail() }
        if case .a(let h)? = j["active_by_hour"] { XCTAssertEqual(h.count, 24); XCTAssertEqual(h[10].dbl, 2500) } else { XCTFail() }
    }

    func testTimelineMergesAndLabelsAway() {
        let evs = [ev(0, "recorder.start"), app(0, "code"), app(100, "x"), app(101, "code"), ev(200, "presence.lock"),
                   ev(300, "presence.unlock"), app(300, "code"), ev(400, "recorder.stop")]
        let j = Query.timeline(day: "2026-11-01", segs: segs(evs), events: evs)
        guard case .a(let items)? = j["items"] else { return XCTFail() }
        XCTAssertEqual(items.map { $0["kind"]?.str }, ["focus", "away", "focus"])
        XCTAssertEqual(items[0]["glances"]?.int, 1)
        XCTAssertEqual(items[0]["dur_s"]?.dbl, 199)
        XCTAssertEqual(items[1]["why"]?.str, "lock")
    }

    func testBrowserURLBackfillFromHistory() {
        let evs = [ev(0, "recorder.start"), app(0, "Dia", title: "me: Pull requests · demo…"), app(100, "code"),
                   app(200, "Dia", title: "me: New Tab"), app(280, "code"), app(300, "Dia", title: "me: Unseen page"), ev(400, "recorder.stop")]
        func visit(_ s: Double, _ url: String, _ title: String, browser: String = "Dia") -> Event {
            ev(s, "source.browser.visit", [("source", .s("browser")), ("id", .s(url)), ("url", .s(url)), ("title", .s(title)), ("browser", .s(browser))])
        }
        let src = [visit(-3000, "https://github.com/demo/pulls", "Pull requests · demo/app"),
                   visit(-10, "https://example.com/other", "Other"),
                   visit(250, "https://news.example.org/a", "Story A"),
                   visit(310, "https://wrong.example/", "Unseen page", browser: "Google Chrome")]
        let out = Query.backfillURLs(segs(evs), sources: src)
        let dia = out.filter { $0.app == "Dia" }
        XCTAssertEqual(dia.map(\.url), ["https://github.com/demo/pulls", "https://news.example.org/a", nil])  // title match; in-segment; other browser ignored
        XCTAssertEqual(dia[0].host, "github.com"); XCTAssertEqual(dia[0].urlSrc, "history")
        XCTAssertNil(out.first { $0.app == "code" }?.url)
        let j = Query.timeline(day: "2026-11-01", segs: segs(evs), events: evs, sources: src)
        guard case .a(let items)? = j["items"] else { return XCTFail() }
        XCTAssertEqual(items.first?["url_src"]?.str, "history")
        XCTAssertEqual(items.first?["host"]?.str, "github.com")
    }

    func testChatsJoinedToMessengerBlocks() {
        let evs = [ev(0, "recorder.start"), app(0, "WeChat"), app(100, "code"), ev(200, "recorder.stop")]
        func msg(_ s: Double, _ chat: String, _ dir: String, source: String = "wechat") -> Event {
            ev(s, "source.\(source).message", [("source", .s(source)), ("id", .s("\(s)")), ("chat_name", .s(chat)), ("direction", .s(dir))])
        }
        let src = [msg(10, "Team", "in"), msg(20, "Team", "out"), msg(30, "Team", "in"), msg(40, "Mom", "out"),
                   msg(150, "Team", "in"), msg(50, "Other", "in", source: "telegram")]
        let j = Query.timeline(day: "2026-11-01", segs: segs(evs), events: evs, sources: src)
        guard case .a(let items)? = j["items"], case .a(let chats)? = items[0]["chats"] else { return XCTFail() }
        XCTAssertEqual(chats.map { $0["chat"]?.str }, ["Team", "Mom"])
        XCTAssertEqual(chats[0]["in"]?.int, 2); XCTAssertEqual(chats[0]["out"]?.int, 1)
        XCTAssertNil(items[1]["chats"])   // the 150 s message arrived while in "code"
    }

    func testTitleCommandsConfig() throws {
        let f = NSTemporaryDirectory() + "lt-cfg-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: f) }
        try #"{"title_commands": {"dev.example.app": ["/usr/local/bin/t", "--x"], "bad.relative": ["t"], "bad.type": "x"}}"#
            .write(toFile: f, atomically: true, encoding: .utf8)
        let c = Config.load(f)
        XCTAssertEqual(c.titleCommands, ["dev.example.app": ["/usr/local/bin/t", "--x"]])
        XCTAssertEqual(c.json["title_commands"]?["dev.example.app"], .a([.s("/usr/local/bin/t"), .s("--x")]))
    }

    func testAt() {
        let evs = [ev(0, "recorder.start"), app(0, "code"), ev(10, "presence.idle_start"), ev(20, "presence.idle_end"),
                   ev(30, "presence.lock"), ev(90, "presence.unlock"), app(90, "code"), ev(120, "recorder.stop")]
        let s = segs(evs)
        XCTAssertEqual(Query.at(at(15), segs: s, events: evs)["state"]?.str, "idle")
        XCTAssertEqual(Query.at(at(25), segs: s, events: evs)["state"]?.str, "active")
        XCTAssertEqual(Query.at(at(60), segs: s, events: evs)["state"]?.str, "away")
        XCTAssertEqual(Query.at(at(60), segs: s, events: evs)["why"]?.str, "lock")
    }
}

final class SchemaDocTests: PinnedZoneCase {
    func testSchemaMarkdownMentionsEveryTypeAndField() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../SCHEMA.md")
        let md = try String(contentsOf: url, encoding: .utf8)
        for t in Schema.types {
            XCTAssertTrue(md.contains("`\(t.type)`"), "SCHEMA.md missing type \(t.type)")
            for f in t.fields { XCTAssertTrue(md.contains("`\(f.name)`"), "SCHEMA.md missing field \(f.name) of \(t.type)") }
        }
    }
}

final class RedactTests: PinnedZoneCase {
    func testMasksSecrets() {
        let cases: [(String, String)] = [
            ("key sk-" + "ant-api03-AbCdEf0123456789xyzXYZ done", "sk-ant"),
            ("token ghp" + "_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_"),
            ("github" + "_pat_11ABCDEFG0123456789_abcdefghijklmnop", "github_pat_"),
            ("aws AKIA" + "IOSFODNN7EXAMPLE x", "IOSFODNN7EXAMPLE"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "eyJhbGci"),
            ("password=hunter2xyz", "hunter2xyz"),
            ("\"api_key\": \"abc123def456\"", "abc123def456"),
            ("Authorization: Bear" + "er abcdefghijklmnop1234567890", "abcdefghijklmnop1234567890"),
            ("密码：Qwerty!2026", "Qwerty!2026"),
            ("sha 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 end", "9f86d081884c7d659a2feaa0c55ad015"),
            ("blob aGVsbG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCB0b2tlbjEyMw== end", "aGVsbG8gd29ybGQgdGhpcyBpcyBh"),
            ("-----BEGIN OPENSSH PRIVATE" + " KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\n-----END OPENSSH PRIVATE" + " KEY-----", "b3BlbnNzaC1rZXktdjEAAAA"),
        ]
        for (input, secret) in cases {
            let out = Redact.apply(input)
            XCTAssertFalse(out.contains(secret), "not redacted: \(input) -> \(out)")
            XCTAssertTrue(out.contains("[REDACTED"), out)
        }
    }

    func testKeepsOrdinaryText() {
        for s in ["今天下午三点开会，讨论 lifetrace 第二步", "https://github.com/risingjerry/lifetrace/pull/12",
                  "func searchable(_ e: Event) -> (String, String)?", "The password field is empty", "commit 2c32ffd"] {
            XCTAssertEqual(Redact.apply(s), s)
        }
    }

    func testMasksPersonalData() {
        let u = Redact.url("https://example.com/x?h=1#/order-list?from=app&phone=13800000000&flat=29.5&flng=106.5&lat=29.5&lng=106.5&open_id=o1&city_id=18&timestamp=1793022927917")
        for leak in ["13800000000", "29.5", "106.5", "open_id=o1"] { XCTAssertFalse(u.contains(leak), u) }
        for kept in ["from=app", "city_id=18", "timestamp=1793022927917", "h=1"] { XCTAssertTrue(u.contains(kept), u) }
        let q = Redact.url("https://example.com/s?q=swift&page=2&mobile=13900000000&user_email=a%40b.com")
        XCTAssertTrue(q.contains("q=swift") && q.contains("page=2"), q)
        XCTAssertFalse(q.contains("13900000000") || q.contains("a%40b.com"), q)
        let t = Redact.apply("call 13700000000 or mail jane.doe@example.com; order 1793022927917, id 12345678901")
        XCTAssertFalse(t.contains("13700000000") || t.contains("jane.doe@example.com"), t)
        XCTAssertTrue(t.contains("1793022927917") && t.contains("12345678901"), t)
    }

    func testCapAndHash() {
        XCTAssertEqual(TextCap.utf8Prefix("中文abc", 4), "中")
        XCTAssertEqual(TextCap.hash("a"), TextCap.hash("a"))
        XCTAssertNotEqual(TextCap.hash("a"), TextCap.hash("b"))
    }
}

final class InputCountTests: PinnedZoneCase {
    func testLiveCountsGoOnSegmentEnd() {
        let s = Segmenter()
        _ = s.feed(ev(0, "recorder.start")); _ = s.feed(app(0, "a"))
        s.addInput(InputCounts(keys: 5, clicks: 1, copies: 1))
        s.addInput(InputCounts(keys: 2, pastes: 1))
        let end = s.feed(app(30, "b")).first { $0.type == "segment.end" }!
        XCTAssertEqual(end.int("keys"), 7); XCTAssertEqual(end.int("clicks"), 1)
        XCTAssertEqual(end.int("copies"), 1); XCTAssertEqual(end.int("pastes"), 1)
        // live segmenter ignores activity.minute (the daemon already added the counts); it only gets the seg id
        let m = s.feed(ev(40, "activity.minute", InputCounts(keys: 9).fields))
        XCTAssertNotNil(m[0].str("seg"))
        let end2 = s.feed(ev(50, "recorder.stop")).first { $0.type == "segment.end" }!
        XCTAssertNil(end2.int("keys"))   // no addInput for this segment: input counting off -> fields absent
    }

    func testReplayUsesMinuteRecords() {
        let evs = [ev(0, "recorder.start"), app(0, "a"), ev(60, "activity.minute", InputCounts(keys: 3, scrolls: 2).fields)]
        let (s, out) = feedAll(evs)
        let segId = out.isEmpty ? s.openSeg : nil
        var withSeg = evs; withSeg[2]["seg"] = .s(segId ?? "")
        let r = Log.replay(withSeg, glanceS: 2)
        XCTAssertEqual(r.peekOpen(at: at(90)).first?.int("keys"), 3)
        XCTAssertEqual(r.peekOpen(at: at(90)).first?.int("scrolls"), 2)
    }
}

final class SourceSearchTests: PinnedZoneCase {
    var dir = ""
    var paths: Paths!

    override func setUp() {
        dir = NSTemporaryDirectory() + "lifetrace-test-\(UUID().uuidString)"
        paths = Paths(home: dir, config: dir + "/none.json")
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func appendSource(_ src: String, _ text: String) {
        let d = paths.sources + "/" + src
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let f = d + "/2026-11-01.jsonl"
        if !FileManager.default.fileExists(atPath: f) { FileManager.default.createFile(atPath: f, contents: nil) }
        let fh = FileHandle(forWritingAtPath: f)!; fh.seekToEndOfFile(); fh.write(text.data(using: .utf8)!); try? fh.close()
    }

    func srcLine(_ id: String, _ s: Double, _ title: String) -> String {
        "{\"v\":\"act.v1\",\"ts\":\"\(Zone.iso(at(s)))\",\"type\":\"source.chrome.visit\",\"source\":\"chrome\",\"id\":\"\(id)\",\"title\":\"\(title)\",\"extra\":{\"x\":1}}\n"
    }

    func testIngestDedupePartialAndSearch() throws {
        let j = Journal(paths); let s = Segmenter()
        for e in [ev(0, "recorder.start"), app(0, "code", title: "lifetrace — Index.swift"),
                  ev(10, "content.snapshot", [("text", .s("讨论缓存读取引擎的性能 benchmark"))]),
                  ev(20, "content.selection", [("text", .s("FTS5 trigram tokenizer"))])] {
            for o in s.feed(e) { j.append(o) }
        }
        appendSource("chrome", srcLine("1", 5, "SQLite FTS5 Extension"))
        appendSource("chrome", srcLine("1", 5, "SQLite FTS5 Extension"))      // duplicate id
        appendSource("chrome", "{\"v\":\"act.v1\",\"ts\":\"2026-11-01T10:00:30.000+08:00\",\"type\":\"sou")   // partial last line
        let idx = try Index(paths)
        idx.catchUp()
        XCTAssertEqual(idx.sourceEvents().count, 1)
        appendSource("chrome", "rce.chrome.visit\",\"source\":\"chrome\",\"id\":\"2\",\"title\":\"博客 Notes 记忆\",\"new_field\":[1,2]}\n")
        idx.catchUp()
        XCTAssertEqual(idx.sourceEvents().map { $0.str("id") }, ["1", "2"])
        let incremental = idx.fingerprint()
        idx.reindex(); XCTAssertEqual(idx.fingerprint(), incremental)

        XCTAssertEqual(idx.search("fts5").map(\.kind).sorted(), ["selection", "source"])
        XCTAssertEqual(idx.search("fts5", source: "chrome").count, 1)
        XCTAssertEqual(idx.search("缓存").first?.kind, "snapshot")             // 2-char CJK -> LIKE fallback
        XCTAssertEqual(idx.search("读取引擎").first?.kind, "snapshot")          // trigram
        XCTAssertEqual(idx.search("Index.swift").first?.kind, "title")
        XCTAssertEqual(idx.search("notes 记忆").count, 1)
        XCTAssertTrue(idx.search("nothing-here").isEmpty)
        XCTAssertEqual(idx.search("benchmark", from: at(11)).count, 0)
        let hit = Query.searchResult("benchmark", idx.search("benchmark"))
        XCTAssertEqual(hit["count"]?.int, 1)

        // timeline interleave + at
        let segs = Log.replay(Log.sinceLastStart(paths), glanceS: 2).peekOpen(at: at(60)).map { Seg($0) }
        let tl = Query.interleave(Query.timeline(day: "2026-11-01", segs: segs, events: []), idx.sourceEvents())
        guard case .a(let items)? = tl["items"] else { return XCTFail() }
        XCTAssertEqual(items.map { $0["kind"]?.str }, ["focus", "source", "source"])
        XCTAssertEqual(items[1]["summary"]?.str, "SQLite FTS5 Extension")
        let a = Query.at(at(6), segs: segs, events: idx.events(), sources: idx.sourceEvents())
        guard case .a(let near)? = a["events"] else { return XCTFail() }
        XCTAssertTrue(near.contains { $0["source"]?.str == "chrome" })
    }
}

// MARK: review fixes (2026-11-01)

final class ReviewFixTests: PinnedZoneCase {
    var dir = ""
    var paths: Paths!

    override func setUp() {
        dir = NSTemporaryDirectory() + "lifetrace-test-\(UUID().uuidString)"
        paths = Paths(home: dir, config: dir + "/none.json")
    }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.events)
        try? FileManager.default.removeItem(atPath: dir)
    }

    // #1 focus metadata is redacted; URLs lose userinfo and credential parameters.
    func testFocusMetadataRedacted() {
        let c = FocusCtx(app: "t", bundle: "t", title: "export password=hunter2xyz", doc: "/tmp/token=abcdef123456/notes.txt",
                         url: "https://bob:pw123@example.com/cb?q=swift&access_token=AAA111&code=xyz&keyword=k#id_token=BBB&x=1").redacted()
        XCTAssertFalse(c.title!.contains("hunter2xyz"))
        XCTAssertFalse(c.doc!.contains("abcdef123456"))
        let u = c.url!
        for secret in ["bob", "pw123", "AAA111", "code=xyz", "BBB"] { XCTAssertFalse(u.contains(secret), u) }
        for kept in ["example.com/cb", "q=swift", "keyword=k", "x=1"] { XCTAssertTrue(u.contains(kept), u) }
        XCTAssertEqual(c.host, "example.com")
        XCTAssertEqual(Redact.url("https://github.com/risingjerry/lifetrace/pull/12?tab=files"), "https://github.com/risingjerry/lifetrace/pull/12?tab=files")
    }

    // #3 quoted values masked whole; Bearer in full; parity keys with lifetrace_sources/core.py.
    func testRedactParity() {
        let cases: [(String, [String])] = [
            ("password=\"alpha beta gamma\" next", ["alpha", "beta", "gamma"]),
            ("password='alpha beta gamma'", ["alpha", "beta", "gamma"]),
            ("Authorization: Bearer abcDEF1234", ["abcDEF1234"]),
            ("curl -H 'Authorization: Basic dXNlcjpwYXNz'", ["dXNlcjpwYXNz"]),
            ("bearer shorttok", ["shorttok"]),
            ("token=abcDEF1234567890", ["abcDEF1234567890"]),
            ("access_token: xyz789", ["xyz789"]),
            ("passwd=p4ss", ["p4ss"]), ("apikey=k3y", ["k3y"]), ("API_KEY: \"a b\"", ["a b"]),
            ("access_key=AKX", ["AKX"]), ("secret: s3cr3t", ["s3cr3t"]),
            ("口令：芝麻开门", ["芝麻开门"]), ("令牌: tk-1", ["tk-1"]), ("密码：\"两 个词\"", ["两", "个词"]),
        ]
        for (input, secrets) in cases {
            let out = Redact.apply(input)
            for s in secrets { XCTAssertFalse(out.contains(s), "\(input) -> \(out)") }
        }
        XCTAssertEqual(Redact.apply("The password field is empty"), "The password field is empty")
    }

    // #4 a torn tail is terminated before appending; damaged lines do not cost the rest of the day.
    func testTornTailRepairAndPerLineDecode() throws {
        let f = paths.dayFile("2026-11-01")
        paths.ensure()
        let good = Event(ts: at(0), type: "recorder.start").line() + "\n"
        var bytes = Data(good.utf8)
        bytes.append(contentsOf: Array("{\"v\":\"act.v1\",\"ts\":\"2026-11-01T10:00:01.000+08:00\",\"type\":\"x\",\"t\":\"".utf8) + [0xE4, 0xB8])  // cut inside a UTF-8 char
        try bytes.write(to: URL(fileURLWithPath: f))
        XCTAssertEqual(Log.read(f).map(\.type), ["recorder.start"])        // before: the whole file failed UTF-8 decoding
        let j = Journal(paths)
        j.append(Event(ts: at(2), type: "recorder.stop", [("reason", .s("signal"))]))
        XCTAssertEqual(j.failed, 0)
        XCTAssertEqual(Log.read(f).map(\.type), ["recorder.start", "recorder.stop"])
        XCTAssertEqual(Log.lineCount(f), 3)
        XCTAssertTrue(Log.recovery(paths, glanceS: 2).isEmpty)
    }

    func testWriteFailureIsCounted() {
        paths.ensure()
        XCTAssertEqual(chmod(paths.events, 0o500), 0)
        let j = Journal(paths)
        j.append(Event(ts: at(0), type: "recorder.start"))
        XCTAssertEqual(j.failed, 1); XCTAssertEqual(j.written, 0)
        XCTAssertNotNil(j.lastError)
    }

    // #7 / #9 streaming replay; a back-dated idle written into the previous day file belongs to this run.
    func testCrossMidnightIdleReplayed() {
        let j = Journal(paths); let s = Segmenter()
        let late = Zone.parse("2026-11-01T23:59:00.000+08:00")!
        let start = late + 70_000                                   // 00:00:10
        let idle = late + 50_000                                    // last input 23:59:50
        let evs = [Event(ts: late, type: "recorder.start"), Event(ts: late, type: "focus.app", FocusCtx(app: "a", bundle: "a").fields),
                   Event(ts: late + 30_000, type: "recorder.stop", [("reason", .s("signal"))]),
                   Event(ts: start, type: "recorder.start"), Event(ts: start, type: "focus.app", FocusCtx(app: "b", bundle: "b").fields),
                   Event(ts: idle, type: "presence.idle_start", [("detected", .s(Zone.iso(start + 40_000)))])]
        for e in evs { for o in s.feed(e) { j.append(o) } }
        XCTAssertEqual(paths.dayFiles(), ["2026-11-01.jsonl", "2026-11-02.jsonl"])
        let run = Log.sinceLastStart(paths)
        XCTAssertEqual(run.map(\.type), ["recorder.start", "focus.app", "presence.idle_start"])
        let r = Log.replayLastRun(paths, glanceS: 2).0
        XCTAssertEqual(r.peekOpen(at: start + 60_000).first?["idle_s"]?.dbl, 60)    // whole segment idle
    }

    // #5 any SQLite failure rolls back: no offsets advanced, nothing half-indexed.
    func testIndexFailureRollsBack() throws {
        let j = Journal(paths); let s = Segmenter()
        for e in [ev(0, "recorder.start"), app(0, "a", title: "hello world"), app(30, "b"), ev(40, "recorder.stop")] { for o in s.feed(e) { j.append(o) } }
        let idx = try Index(paths)
        let empty = idx.fingerprint()
        XCTAssertTrue(idx.exec("CREATE TRIGGER boom BEFORE INSERT ON segments BEGIN SELECT RAISE(ABORT, 'boom'); END"))
        XCTAssertNil(idx.catchUp())
        XCTAssertEqual(idx.fingerprint(), empty)                     // before: events/fts/offsets committed without segments
        XCTAssertTrue(idx.exec("DROP TRIGGER boom"))
        // write lock held by another connection: BEGIN fails, nothing happens
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(paths.index, &other), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        sqlite3_busy_timeout(idx.db, 0)
        XCTAssertNil(idx.catchUp())
        sqlite3_exec(other, "ROLLBACK", nil, nil, nil); sqlite3_close(other)
        XCTAssertNotNil(idx.catchUp())
        let incremental = idx.fingerprint()
        XCTAssertNotNil(idx.reindex())
        XCTAssertEqual(idx.fingerprint(), incremental)
        XCTAssertEqual(idx.segments(from: T0, to: T0 + Zone.dayMs).count, 2)
    }

    // #7 the per-segment title set is bounded.
    func testTitleSetBounded() {
        let s = Segmenter()
        _ = s.feed(ev(0, "recorder.start")); _ = s.feed(app(0, "term", win: 1, title: "t0"))
        for i in 1...1000 { _ = s.feed(ev(Double(i), "focus.title", FocusCtx(app: "term", bundle: "term", pid: 1, win: 1, title: "t\(i)").fields)) }
        XCTAssertEqual(s.open?.titles.count, Segmenter.maxTitles)
        let end = s.feed(ev(2000, "recorder.stop")).first { $0.type == "segment.end" }!
        XCTAssertEqual(end.int("titles"), Int64(Segmenter.maxTitles))
        XCTAssertEqual(end["titles_capped"]?.bool, true)
    }

    // #8 an idle period detected later reaches back into a segment closed by a no-input URL change.
    func testRetroactiveIdleRevisesClosedSegment() throws {
        let s = Segmenter()
        _ = s.feed(ev(0, "recorder.start"))
        _ = s.feed(app(0, "br", win: 1, url: "https://a.com/"))
        s.addInput(InputCounts(keys: 1))                                         // typed at ~0 s
        let first = s.feed(ev(30, "focus.title", FocusCtx(app: "br", bundle: "br", pid: 1, win: 1, url: "https://b.com/").fields))
        XCTAssertEqual(first.first?["active_s"]?.dbl, 30)                        // written as active, idle not known yet
        let out = s.feed(ev(5, "presence.idle_start", [("detected", .s(Zone.iso(at(65))))]))
        let rev = out.filter { $0.type == "segment.end" }
        XCTAssertEqual(rev.count, 1)
        XCTAssertEqual(rev[0].str("seg"), first[0].str("seg"))
        XCTAssertEqual(rev[0]["revised"]?.bool, true)
        XCTAssertEqual(rev[0]["idle_s"]?.dbl, 25); XCTAssertEqual(rev[0]["active_s"]?.dbl, 5)
        XCTAssertEqual(rev[0].int("keys"), 1)
        // input after a close means no revision
        let s2 = Segmenter()
        _ = s2.feed(ev(0, "recorder.start")); _ = s2.feed(app(0, "a")); _ = s2.feed(app(30, "b"))
        s2.addInput(InputCounts(clicks: 1))
        _ = s2.feed(ev(31, "activity.minute"))
        XCTAssertTrue(s2.feed(ev(10, "presence.idle_start")).filter { $0.type == "segment.end" }.isEmpty)
        // the index keeps the last record for (seg, part)
        let j = Journal(paths)
        for e in [ev(0, "recorder.start")] + first + out { j.append(e) }
        let idx = try Index(paths); idx.catchUp()
        XCTAssertEqual(idx.segments(from: T0, to: T0 + Zone.dayMs).first?.idle, 25)
    }

    // #15 a segment ending exactly at Beijing midnight is filed under the day it covers.
    func testSegmentEndingAtMidnight() {
        let mid = Zone.dayStart("2026-11-02")!
        let s = Segmenter()
        _ = s.feed(Event(ts: mid - 60_000, type: "recorder.start"))
        _ = s.feed(Event(ts: mid - 60_000, type: "focus.app", FocusCtx(app: "a", bundle: "a").fields))
        let segs = s.feed(Event(ts: mid, type: "focus.app", FocusCtx(app: "b", bundle: "b").fields)).filter { $0.type == "segment.end" }
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].ts, mid - 1)
        XCTAssertEqual(Zone.day(segs[0].ts), "2026-11-01")
        XCTAssertEqual(segs[0].str("end"), "2026-11-02T00:00:00.000+08:00")
    }
}
