import Foundation

public struct Config {
    public var idleThresholdS: Double = 60
    public var idlePollS: Double = 3
    public var titleThrottleS: Double = 5
    public var glanceS: Double = 2
    public var ax: Bool = true
    public var browserAppleScript: Bool = false
    /// Layer 4: count keys/clicks/scrolls/copy/paste (counts only).
    public var inputCounts: Bool = true
    /// Layer 5: visible text of the focused window via Accessibility.
    public var content: Bool = true
    /// Bundle ids that never get layer-5 content. A trailing `*` matches a prefix. Replaces the defaults when set.
    public var contentExcludeBundles: [String] = Config.defaultContentExclude
    /// Fixed UTC offset for day files and ISO times, e.g. "+08:00" (see `Zone`). nil = machine offset at start.
    public var utcOffset: String?

    public static let defaultContentExclude = [
        "com.1password.*", "com.agilebits.*", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
        "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.*", "in.sinew.Enpass-Desktop",
        "so.onekey.wallet.desktop", "com.ledger.*",
        "com.alipay.*", "com.antgroup.*", "com.cmbchina.*", "cmb.pb", "com.icbc.*", "com.ccb.*", "com.boc.*",
        "com.abchina.*", "com.bankcomm.*", "com.paypal.*",
    ]

    public init() {}

    public func contentExcluded(_ bundle: String?) -> Bool {
        guard let b = bundle else { return false }
        return contentExcludeBundles.contains { $0.hasSuffix("*") ? b.hasPrefix($0.dropLast()) : b == $0 }
    }

    /// Optional JSON file; unknown keys ignored, missing keys keep defaults.
    public static func load(_ path: String) -> Config {
        var c = Config()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let j = J.parse(text) else { return c }
        if let v = j["idle_threshold_s"]?.dbl, v >= 5 { c.idleThresholdS = v }
        if let v = j["idle_poll_s"]?.dbl, v >= 1 { c.idlePollS = v }
        if let v = j["title_throttle_s"]?.dbl, v >= 0.5 { c.titleThrottleS = v }
        if let v = j["glance_s"]?.dbl, v >= 0 { c.glanceS = v }
        if let v = j["ax"]?.bool { c.ax = v }
        if let v = j["browser_applescript"]?.bool { c.browserAppleScript = v }
        if let v = j["input_counts"]?.bool { c.inputCounts = v }
        if let v = j["content"]?.bool { c.content = v }
        if case .a(let xs)? = j["content_exclude_bundles"] { c.contentExcludeBundles = xs.compactMap(\.str) }
        if let v = j["utc_offset"]?.str, Zone.parseOffset(v) != nil { c.utcOffset = v }
        return c
    }

    public var json: J {
        .o([("idle_threshold_s", .d(idleThresholdS)), ("idle_poll_s", .d(idlePollS)), ("title_throttle_s", .d(titleThrottleS)),
            ("glance_s", .d(glanceS)), ("ax", .b(ax)), ("browser_applescript", .b(browserAppleScript)),
            ("input_counts", .b(inputCounts)), ("content", .b(content)),
            ("content_exclude_bundles", .a(contentExcludeBundles.map { .s($0) })), ("utc_offset", .s(Zone.suffix))])
    }
}

public struct Paths {
    public let home: String
    public let config: String
    public var events: String { home + "/events" }
    public var index: String { home + "/index.sqlite" }
    public var state: String { home + "/state.json" }
    public var control: String { home + "/control.json" }
    public var lock: String { home + "/daemon.lock" }
    /// External readers write act.v1 JSONL here: sources/<source>/YYYY-MM-DD.jsonl (see SOURCES.md).
    public var sources: String { home + "/sources" }

    public init(home: String? = nil, config: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        // $HOME first (like other CLIs, and so a temporary HOME isolates a test install), else the account's home.
        let h = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        self.home = home ?? env["LIFETRACE_HOME"] ?? h + "/.local/share/lifetrace"
        self.config = config ?? env["LIFETRACE_CONFIG"] ?? h + "/.config/lifetrace/config.json"
    }

    public func ensure() {
        try? FileManager.default.createDirectory(atPath: events, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    public func dayFile(_ day: String) -> String { events + "/\(day).jsonl" }

    /// Source day files as "<source>/YYYY-MM-DD.jsonl", ascending.
    public func sourceFiles() -> [String] {
        let fm = FileManager.default
        var res: [String] = []
        for src in ((try? fm.contentsOfDirectory(atPath: sources)) ?? []).sorted() where !src.hasPrefix(".") {
            let names = (try? fm.contentsOfDirectory(atPath: sources + "/" + src)) ?? []
            res += names.filter { $0.hasSuffix(".jsonl") }.sorted().map { src + "/" + $0 }
        }
        return res
    }

    /// Day files, ascending ("YYYY-MM-DD.jsonl").
    public func dayFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: events)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && $0.count == 16 }.sorted()
    }
}

/// Append-only writer. Each record goes into the file of the local day (configured offset) of its `ts`.
/// Only the daemon (holding `daemon.lock`) writes; when it opens a day file whose last line is incomplete
/// (an earlier crash or full disk) it first terminates that line, so it stays one isolated bad line.
public final class Journal {
    let paths: Paths
    var fd: Int32 = -1
    var fdDay = ""
    public private(set) var written = 0
    /// Records that could not be written completely (open/write error, e.g. disk full).
    public private(set) var failed = 0
    public private(set) var lastError: String?

    public init(_ paths: Paths) { self.paths = paths; paths.ensure() }
    deinit { if fd >= 0 { close(fd) } }

    /// Writes all of `bytes`, retrying on EINTR and short writes. Returns errno on failure.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32? {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            return n < 0 ? errno : EIO
        }
        return nil
    }

    func fail(_ what: String, _ err: Int32) {
        failed += 1
        lastError = "\(what): \(String(cString: strerror(err)))"
    }

    public func append(_ e: Event) {
        let day = Zone.day(e.ts)
        if day != fdDay {
            if fd >= 0 { close(fd) }
            fd = open(paths.dayFile(day), O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            fdDay = fd >= 0 ? day : ""
            if fd < 0 { fail("open \(day)", errno); return }
            var last: UInt8 = 10
            let size = lseek(fd, 0, SEEK_END)
            if size > 0, pread(fd, &last, 1, size - 1) == 1, last != 10, let err = Journal.writeAll(fd, [10]) {
                fail("repair \(day)", err)
            }
        }
        let bytes = Array((e.line() + "\n").utf8)
        if let err = Journal.writeAll(fd, bytes) {
            fail("write \(day)", err)
            // A partial record must not swallow the next one: close so the next append repairs the tail.
            close(fd); fd = -1; fdDay = ""
            return
        }
        written += 1
    }
}

public enum Log {
    /// Calls `body` with every complete line of `path` from byte `offset` on (and a final unterminated one),
    /// reading in bounded chunks. Each line is decoded on its own, so a damaged line costs only itself.
    /// `body` gets the line and the byte offset where it starts.
    public static func eachLine(_ path: String, from offset: UInt64 = 0, _ body: (Data, UInt64) -> Void) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        if offset > 0 { try? fh.seek(toOffset: offset) }
        var pending = Data(), pos = offset
        while true {
            let chunk = (try? fh.read(upToCount: 1 << 16)) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let nl = pending[start...].firstIndex(of: 10) {
                body(pending[start..<nl], pos); pos += UInt64(nl - start + 1)
                start = nl + 1
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { body(pending, pos) }
    }

    static func parse(_ line: Data) -> Event? {
        guard !line.isEmpty, let text = String(data: line, encoding: .utf8) else { return nil }
        return Event.parse(Substring(text))
    }

    /// Reads all events of one day file (corrupt lines skipped).
    public static func read(_ path: String) -> [Event] {
        var res: [Event] = []
        eachLine(path) { line, _ in if let e = parse(line) { res.append(e) } }
        return res
    }

    /// Calls `body` with the events since the most recent `recorder.start` (searching back at most `maxDays`
    /// files), streaming: memory does not grow with the length of the run.
    /// Idle starts are back-dated, so one detected in this run can sit in the previous day file; those
    /// (`detected` at or after the run's start) are fed in detection order.
    public static func forEachSinceLastStart(_ paths: Paths, maxDays: Int = 7, _ body: (Event) -> Void) {
        let files = paths.dayFiles().suffix(maxDays).map { paths.events + "/" + $0 }
        let marker = Data(#""type":"recorder.start""#.utf8)
        var startFile = files.startIndex, startOffset: UInt64 = 0, startTs: Int64?
        for i in files.indices.reversed() {
            var found: (UInt64, Int64)?
            eachLine(files[i]) { line, off in
                if line.range(of: marker) != nil, let e = parse(line), e.type == "recorder.start" { found = (off, e.ts) }
            }
            if let (off, ts) = found { startFile = i; startOffset = off; startTs = ts; break }
        }
        var late: [Event] = []
        if let startTs, startFile > files.startIndex {
            let idleMarker = Data(#""type":"presence.idle_start""#.utf8)
            eachLine(files[startFile - 1]) { line, _ in
                guard line.range(of: idleMarker) != nil, let e = parse(line),
                      let d = e.str("detected").flatMap({ Zone.parse($0) }), d >= startTs else { return }
                late.append(e)
            }
        }
        func detected(_ e: Event) -> Int64 { e.str("detected").flatMap { Zone.parse($0) } ?? e.ts }
        late.sort { detected($0) < detected($1) }
        for i in startFile..<files.endIndex {
            eachLine(files[i], from: i == startFile ? startOffset : 0) { line, _ in
                guard let e = parse(line) else { return }
                while let l = late.first, e.type != "recorder.start", detected(l) <= e.ts || e.type == "recorder.stop" { body(l); late.removeFirst() }
                body(e)
            }
        }
        late.forEach(body)
    }

    /// Events since the most recent `recorder.start` as an array (tests and small runs).
    public static func sinceLastStart(_ paths: Paths, maxDays: Int = 7) -> [Event] {
        var acc: [Event] = []
        forEachSinceLastStart(paths, maxDays: maxDays) { acc.append($0) }
        return acc
    }

    /// Replays a run's events through a fresh Segmenter (outputs discarded) and returns it.
    public static func replay(_ evs: [Event], glanceS: Double) -> Segmenter {
        let s = Segmenter(glanceS: glanceS)
        s.replayInput = true
        for e in evs { _ = s.feed(e) }
        return s
    }

    /// Streaming replay of the most recent run. Returns the segmenter, the last event and the largest `ts` seen.
    public static func replayLastRun(_ paths: Paths, glanceS: Double) -> (Segmenter, last: Event?, maxTs: Int64?) {
        let s = Segmenter(glanceS: glanceS)
        s.replayInput = true
        var last: Event?, maxTs: Int64?
        forEachSinceLastStart(paths) { e in
            _ = s.feed(e); last = e; maxTs = max(maxTs ?? e.ts, e.ts)
        }
        return (s, last, maxTs)
    }

    /// If the last run did not end with `recorder.stop`, returns the records that close it
    /// (pending `segment.end` + `recorder.stop` with reason "crash") at the last recorded instant.
    public static func recovery(_ paths: Paths, glanceS: Double) -> [Event] {
        let (s, last, maxTs) = replayLastRun(paths, glanceS: glanceS)
        guard let last, last.type != "recorder.stop" else { return [] }
        return s.feed(Event(ts: maxTs ?? last.ts, type: "recorder.stop", [("reason", .s("crash"))]))
    }

    public static func lineCount(_ path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path) else { return 0 }
        return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }
}
