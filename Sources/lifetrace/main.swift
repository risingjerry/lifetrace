import Foundation
import ApplicationServices
import AppKit
import LifetraceCore

let usage = """
lifetrace \(lifetraceVersion) — a local record of how you use this Mac (no screen recording, screenshots or audio)

  lifetrace daemon                         run the recorder in the foreground (what the LaunchAgent runs)
  lifetrace status [--json]                recording or not, memory/CPU, permissions, today's event count
  lifetrace timeline [DATE] [--raw] [--sources] [--json]   one day's timeline (default today; --sources interleaves external sources)
  lifetrace at TIME [--json]               what was happening at one moment ("14:30", "2026-11-01 14:30", ISO)
  lifetrace stats [--day DATE | --week [DATE]] [--top N] [--json]   time per app/site/window, focus, switches
  lifetrace events [--seg ID] [--from T] [--to T] [--type PREFIX] [--source NAME] [--limit N]   raw events (JSON lines)
  lifetrace search QUERY [--from T] [--to T] [--source NAME|act] [--limit N] [--json]   full-text search of seen text, titles, sources
  lifetrace tail [--json]                  follow new events live
  lifetrace schema [--json]                the act.v1 data format
  lifetrace pause [--minutes N] | resume   pause / resume recording
  lifetrace reindex                        rebuild the SQLite index from the JSONL log

Dates and times use one fixed UTC offset: $LIFETRACE_UTC_OFFSET, config "utc_offset" (e.g. "+08:00"),
else this Mac's offset when the command starts.
Environment: LIFETRACE_HOME (data dir, default ~/.local/share/lifetrace), LIFETRACE_CONFIG
(default ~/.config/lifetrace/config.json), LIFETRACE_UTC_OFFSET.
"""

var args = Array(CommandLine.arguments.dropFirst())
let cmd = args.isEmpty ? "help" : args.removeFirst()
let wantJSON = args.contains("--json")
args.removeAll { $0 == "--json" }

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
var positional: [String] {
    var res: [String] = []; var skip = false
    for a in args {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = !["--raw", "--week", "--sources"].contains(a); continue }
        res.append(a)
    }
    return res
}

func die(_ msg: String, _ code: Int32 = 2) -> Never {
    if wantJSON { print(J.o([("v", .s(schemaVersion)), ("error", .s(msg))]).encode()) }
    else { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }
    exit(code)
}

let paths = Paths()
let cfg = Config.load(paths.config)
Zone.configure(ProcessInfo.processInfo.environment["LIFETRACE_UTC_OFFSET"], cfg.utcOffset)

func daemonPid() -> pid_t? {
    let fd = open(paths.lock, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }   // nobody holds it
    let st = (try? String(contentsOfFile: paths.state, encoding: .utf8)).flatMap { J.parse($0) }
    return st?["pid"]?.int.map { pid_t($0) }
}

func openIndex() -> Index {
    guard let idx = try? Index(paths) else { die("cannot open index at \(paths.index)") }
    if idx.catchUp() == nil { FileHandle.standardError.write("lifetrace: index busy, answering from the last committed state\n".data(using: .utf8)!) }
    return idx
}

/// The segment still in progress (not yet in the log), when the daemon is running.
func liveSegs() -> [Seg] {
    guard daemonPid() != nil else { return [] }
    let s = Log.replayLastRun(paths, glanceS: cfg.glanceS).0
    return s.peekOpen(at: Zone.nowMs()).map { Seg($0) }
}

func hm(_ s: Double) -> String {
    let m = Int(s / 60)
    if m >= 60 { return "\(m / 60)h\(m % 60)m" }
    if m > 0 { return "\(m)m" }
    return "\(Int(s))s"
}
func clock(_ iso: String?) -> String { iso.map { String($0.dropFirst(11).prefix(5)) } ?? "?" }
func out(_ j: J, _ human: () -> Void) { if wantJSON { print(j.encode()) } else { human() } }

func dayArg(_ s: String?) -> String {
    guard let s else { return Zone.today() }
    if s == "today" { return Zone.today() }
    if s == "yesterday" { return Zone.addDays(Zone.today(), -1) }
    guard Zone.dayStart(s) != nil else { die("bad date \(s); use YYYY-MM-DD") }
    return s
}

switch cmd {
case "daemon":
    Daemon(paths: paths, cfg: cfg).run()

case "status":
    let pid = daemonPid()
    let st = (try? String(contentsOfFile: paths.state, encoding: .utf8)).flatMap { J.parse($0) }
    let ps = pid.flatMap { ProcStats.of($0) }
    let today = Zone.today()
    let n = Log.lineCount(paths.dayFile(today))
    var last: Event?
    Log.eachLine(paths.dayFile(today)) { line, _ in
        if let text = String(data: line, encoding: .utf8), let e = Event.parse(Substring(text)), e.ts > (last?.ts ?? .min) { last = e }
    }
    var kv: [(String, J)] = [("v", .s(schemaVersion)), ("query", .s("status")), ("recording", .b(pid != nil && st?["paused"]?.bool != true)),
        ("running", .b(pid != nil)), ("pid", pid.map { .i(Int64($0)) } ?? .null)]
    if let ps {
        kv += [("memory_mb", .d(ps.footprintMB)), ("rss_mb", .d(ps.rssMB)), ("cpu_avg_pct", .d(ps.avgCPUPercent)),
               ("cpu_s", .d(ps.cpuSeconds)), ("uptime_s", .d(ps.uptimeSeconds))]
    }
    kv += [("paused", st?["paused"] ?? .b(false)), ("paused_until", st?["paused_until"] ?? .null),
           ("permissions", .o([("accessibility", st?["ax_trusted"] ?? .null), ("window_level", st?["ax"] ?? .null),
                               ("input_counts", st?["input"] ?? .null), ("input_listen_access", st?["input_listen_access"] ?? .null),
                               ("screen_recording", .s("never requested")), ("automation", .s(cfg.browserAppleScript ? "used for browser URL" : "not used"))])),
           ("level", .s(st?["ax"]?.bool == true ? "window" : "app")),
           ("write_errors", st?["write_errors"] ?? .i(0)), ("last_write_error", st?["last_write_error"] ?? .null),
           ("today", .s(today)), ("today_events", .i(Int64(n))), ("last_event", last.map { .s(Zone.iso($0.ts)) } ?? .null),
           ("data_dir", .s(paths.home)), ("config", cfg.json)]
    out(.o(kv)) {
        print(pid == nil ? "Recorder: not running" : (st?["paused"]?.bool == true ? "Recorder: paused (pid \(pid!))" : "Recorder: recording (pid \(pid!))"))
        if let ps { print(String(format: "Resources: memory %.1f MB (RSS %.1f MB), average CPU %.3f%%, up %@", ps.footprintMB, ps.rssMB, ps.avgCPUPercent, hm(ps.uptimeSeconds))) }
        if pid != nil {
            print(st?["ax"]?.bool == true ? "Permission: Accessibility granted -> window/title/document level" : "Permission: Accessibility not granted or turned off -> app level only (System Settings > Privacy & Security > Accessibility: turn on lifetrace)")
            if cfg.inputCounts {
                print(st?["input"]?.bool == true ? "Input counts: on (counts of keys/clicks/scrolls/copy/paste only)" : "Input counts: unavailable (event listening denied; allow lifetrace in Accessibility or Input Monitoring, then restart it)")
            }
        }
        if let w = st?["write_errors"]?.int, w > 0 { print("Write errors: \(w) (\(st?["last_write_error"]?.str ?? "?")); check free disk space") }
        print("Today (\(today)): \(n) events, last \(last.map { Zone.iso($0.ts) } ?? "none")")
        print("Data dir: \(paths.home)")
    }

case "timeline":
    let day = dayArg(positional.first)
    let idx = openIndex()
    guard let from = Zone.dayStart(day) else { die("bad date") }
    let live = liveSegs().filter { $0.startMs >= from && $0.startMs < from + Zone.dayMs }
    let segs = idx.segments(from: from, to: from + Zone.dayMs) + live
    let evs = idx.events(from: from - 60_000, to: from + Zone.dayMs, limit: 100_000).filter { $0.type.hasPrefix("presence.") || $0.type.hasPrefix("recorder.") }
    var j = Query.timeline(day: day, segs: segs, events: evs, openSegs: Set(live.map(\.seg)), raw: flag("--raw"))
    if flag("--sources") { j = Query.interleave(j, idx.sourceEvents(from: from, to: from + Zone.dayMs, limit: 100_000)) }
    out(j) {
        print("\(day) timeline (UTC\(Zone.suffix))")
        if case .a(let items)? = j["items"] {
            for it in items {
                if it["kind"]?.str == "source" {
                    print("  \(clock(it["ts"]?.str))        · [\(it["source"]?.str ?? "")] \(it["summary"]?.str ?? "")")
                } else if it["kind"]?.str == "away" {
                    print("  \(clock(it["start"]?.str))–\(clock(it["end"]?.str))  · away (\(it["why"]?.str ?? "")) \(hm(it["dur_s"]?.dbl ?? 0))")
                } else {
                    let what = [it["app"]?.str, it["host"]?.str ?? it["title"]?.str].compactMap { $0 }.joined(separator: " — ")
                    let extra = (it["glances"]?.int ?? 0) > 0 ? ", \(it["glances"]!.int!) glances elsewhere" : ""
                    print("  \(clock(it["start"]?.str))–\(clock(it["end"]?.str))  \(what)  active \(hm(it["active_s"]?.dbl ?? 0)) of \(hm(it["dur_s"]?.dbl ?? 0))\(extra)\(it["open"] != nil ? " (in progress)" : "")")
                }
            }
        }
        if let t = j["totals"] { print("Total: at the computer \(hm(t["tracked_s"]?.dbl ?? 0)), active \(hm(t["active_s"]?.dbl ?? 0)), \(t["segments"]?.int ?? 0) segments") }
    }

case "at":
    guard !positional.isEmpty, let t = Zone.parse(positional.joined(separator: " ")) else { die("usage: lifetrace at TIME") }
    let idx = openIndex()
    let live = liveSegs()
    let segs = idx.segments(from: t - Zone.dayMs, to: t + Zone.dayMs) + live
    let evs = idx.events(from: t - 6 * 3_600_000, to: t + 3_600_000, limit: 100_000)
    let j = Query.at(t, segs: segs, events: evs, openSegs: Set(live.map(\.seg)),
                     sources: idx.sourceEvents(from: t - 120_000, to: t + 120_001, limit: 500))
    out(j) {
        let st = ["active": "using the computer", "idle": "computer on, no input", "away": "away (\(j["why"]?.str ?? ""))", "unknown": "nothing recorded"][j["state"]?.str ?? ""] ?? ""
        print("\(Zone.iso(t)): \(st)")
        if let s = j["segment"], !s.isNull {
            print("  \(s["app"]?.str ?? "?")  \(s["title"]?.str ?? "")  \(s["url"]?.str ?? s["doc"]?.str ?? "")")
            print("  this segment \(clock(s["start"]?.str))–\(clock(s["end"]?.str)), \(hm(s["dur_s"]?.dbl ?? 0)) (seg \(s["seg"]?.str ?? ""))")
        }
    }

case "stats":
    let week = flag("--week")
    let end = dayArg(opt("--day") ?? positional.first)
    let days = week ? (0..<7).map { Zone.addDays(end, $0 - 6) } : [end]
    let idx = openIndex()
    guard let from = Zone.dayStart(days[0]), let to = Zone.dayStart(end).map({ $0 + Zone.dayMs }) else { die("bad date") }
    let live = liveSegs().filter { $0.startMs >= from && $0.startMs < to }
    let j = Query.stats(days: days, segs: idx.segments(from: from, to: to) + live, top: Int(opt("--top") ?? "") ?? 15)
    out(j) {
        let t = j["totals"]
        print("\(days.first!)\(days.count > 1 ? " to \(end)" : "") stats (UTC\(Zone.suffix))")
        print("  at the computer \(hm(t?["tracked_s"]?.dbl ?? 0)), active \(hm(t?["active_s"]?.dbl ?? 0)), \(j["app_switches"]?.int ?? 0) app switches, \(j["interruptions"]?.int ?? 0) interruptions, \(j["deep_focus_blocks"]?.int ?? 0) focus blocks of 25+ min")
        if let l = j["longest_focus"], !l.isNull { print("  longest focus: \(l["app"]?.str ?? "?") \(clock(l["start"]?.str))–\(clock(l["end"]?.str)), \(hm(l["active_s"]?.dbl ?? 0))") }
        for (title, key, name) in [("by app", "by_app", "app"), ("by site", "by_domain", "host")] {
            guard case .a(let rows)? = j[key], !rows.isEmpty else { continue }
            print("  \(title):")
            for r in rows.prefix(10) { print(String(format: "    %-28@ %@  (%.0f%%)", (r[name]?.str ?? "?") as NSString, hm(r["active_s"]?.dbl ?? 0), (r["share"]?.dbl ?? 0) * 100)) }
        }
    }

case "events":
    let idx = openIndex()
    let (f, t, lim) = (opt("--from").flatMap { Zone.parse($0) }, opt("--to").flatMap { Zone.parse($0) }, Int(opt("--limit") ?? "") ?? 500)
    let evs = opt("--source").map { idx.sourceEvents(from: f, to: t, source: $0, typePrefix: opt("--type"), limit: lim) }
        ?? idx.events(from: f, to: t, typePrefix: opt("--type"), seg: opt("--seg"), limit: lim)
    if wantJSON { print(J.o([("v", .s(schemaVersion)), ("query", .s("events")), ("count", .i(Int64(evs.count))), ("events", .a(evs.map(\.json)))]).encode()) }
    else { for e in evs { print(e.line()) } }

case "search":
    let q = positional.joined(separator: " ")
    guard !q.isEmpty else { die("usage: lifetrace search QUERY [--from T] [--to T] [--source NAME|act] [--limit N]") }
    let idx = openIndex()
    let hits = idx.search(q, from: opt("--from").flatMap { Zone.parse($0) }, to: opt("--to").flatMap { Zone.parse($0) },
                          source: opt("--source"), limit: Int(opt("--limit") ?? "") ?? 50)
    let j = Query.searchResult(q, hits)
    out(j) {
        print("Search \"\(q)\": \(hits.count) hits (newest first)")
        if case .a(let items)? = j["hits"] {
            for h in items {
                print("  \(h["ts"]?.str?.prefix(16).replacingOccurrences(of: "T", with: " ") ?? "")  [\(h["source"]?.str ?? "")/\(h["kind"]?.str ?? "")] \(h["app"]?.str ?? "")  \(h["snippet"]?.str ?? "")")
            }
        }
    }

case "tail":
    setvbuf(stdout, nil, _IOLBF, 0)
    var day = Zone.today()
    var offset: UInt64 = (try? FileManager.default.attributesOfItem(atPath: paths.dayFile(day))[.size] as? UInt64) ?? 0
    paths.ensure()
    func drain() {
        if Zone.today() != day { day = Zone.today(); offset = 0 }
        guard let fh = FileHandle(forReadingAtPath: paths.dayFile(day)) else { return }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data(); try? fh.close()
        guard let nl = data.lastIndex(of: 10) else { return }
        offset += UInt64(nl - data.startIndex + 1)
        for line in String(decoding: data[data.startIndex...nl], as: UTF8.self).split(separator: "\n") {
            if wantJSON { print(line) }
            else if let e = Event.parse(line) {
                let what = [e.str("app"), e.str("title"), e.str("url") ?? e.str("doc"), e["dur_s"].map { "\($0.dbl ?? 0)s" }, e.str("reason")].compactMap { $0 }.joined(separator: "  ")
                print("\(clock(Zone.iso(e.ts)))\(Zone.iso(e.ts).dropFirst(16).prefix(3))  \(e.type)  \(what)")
            }
        }
    }
    // Event-driven: wake on writes to the events directory (any day file).
    let dirFD = open(paths.events, O_EVTONLY)
    var fileSrc: DispatchSourceFileSystemObject?
    func watchFile() {
        fileSrc?.cancel()
        let fd = open(paths.dayFile(day), O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write], queue: .main)
        s.setEventHandler { drain() }
        s.setCancelHandler { close(fd) }
        s.resume(); fileSrc = s
    }
    let dirSrc = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: .write, queue: .main)
    dirSrc.setEventHandler { drain(); watchFile() }
    dirSrc.resume()
    watchFile()
    dispatchMain()

case "schema":
    if wantJSON { print(Schema.json.encode()); break }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let candidates = [exe.appendingPathComponent("../share/lifetrace/SCHEMA.md").path, exe.appendingPathComponent("../../SCHEMA.md").path,
                      paths.home + "/SCHEMA.md"]
    if let text = candidates.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first { print(text) }
    else {
        for t in Schema.types { print("\(t.type): \(t.desc)"); for f in t.fields { print("  \(f.name) (\(f.type)): \(f.desc)") } }
    }

case "pause", "resume":
    paths.ensure()
    var kv: [(String, J)] = [("paused", .b(cmd == "pause"))]
    if cmd == "pause", let m = opt("--minutes").flatMap(Double.init) { kv.append(("until", .s(Zone.iso(Zone.nowMs() + Int64(m * 60_000))))) }
    try? (J.o(kv).encode() + "\n").write(toFile: paths.control, atomically: true, encoding: .utf8)
    let pid = daemonPid()
    if let pid { kill(pid, SIGUSR1) }
    out(.o([("v", .s(schemaVersion)), ("query", .s(cmd)), ("ok", .b(true)), ("daemon_running", .b(pid != nil))] + kv)) {
        print(cmd == "pause" ? "Recording paused\(kv.count > 1 ? ", resumes at \(clock(kv[1].1.str))" : "")" : "Recording resumed")
        if pid == nil { print("(the recorder is not running; takes effect when it starts)") }
    }

case "reindex":
    guard let idx = try? Index(paths) else { die("cannot open index") }
    guard let n = idx.reindex() else { die("index busy or not writable; nothing changed, try again") }
    out(.o([("v", .s(schemaVersion)), ("query", .s("reindex")), ("events", .i(Int64(n)))])) { print("Rebuilt the index from JSONL: \(n) events") }

case "_probe-content":
    // Developer aid: one layer-5 read of an app's focused window, printed (nothing is written).
    guard let pid = positional.first.flatMap(Int32.init), let app = NSRunningApplication(processIdentifier: pid) else { die("usage: lifetrace _probe-content PID") }
    let d = Daemon(paths: paths, cfg: cfg)
    d.probeOut = { print($0.line()) }
    d.axTrusted = AXIsProcessTrusted()
    d.observedPid = pid
    d.lastFocus = FocusCtx(app: app.localizedName, bundle: app.bundleIdentifier, pid: Int(pid))
    d.content.snapshot(why: "probe", anyWindow: true)

case "version", "--version":
    print(lifetraceVersion)

default:
    print(usage)
}
