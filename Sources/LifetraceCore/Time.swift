import Foundation

/// Fixed-UTC-offset time helpers (no DST). The offset decides which day file a record goes to and the
/// offset written in every ISO time. Set once at start: $LIFETRACE_UTC_OFFSET, then config `utc_offset`,
/// else the machine's UTC offset at start. It never follows later machine time zone changes.
public enum Zone {
    public private(set) static var offsetMs: Int64 = Int64(TimeZone.current.secondsFromGMT()) * 1000
    public static let dayMs: Int64 = 86_400_000

    /// "+08:00" / "-05:30" / "Z" -> milliseconds east of UTC, else nil.
    public static func parseOffset(_ text: String?) -> Int64? {
        guard let t = text else { return nil }
        if t == "Z" || t == "z" { return 0 }
        let c = Array(t)
        guard c.count == 6, c[0] == "+" || c[0] == "-", c[3] == ":",
              let h = Int64(String(c[1...2])), let m = Int64(String(c[4...5])), h <= 14, m <= 59 else { return nil }
        return (h * 3_600_000 + m * 60_000) * (c[0] == "-" ? -1 : 1)
    }

    /// Applies the first valid offset; returns false (keeping the current one) when none is valid.
    @discardableResult
    public static func configure(_ candidates: String?...) -> Bool {
        for c in candidates { if let o = parseOffset(c) { offsetMs = o; return true } }
        return false
    }

    /// The configured offset as "+08:00".
    public static var suffix: String {
        let a = abs(offsetMs) / 60000
        return (offsetMs < 0 ? "-" : "+") + p2(a / 60) + ":" + p2(a % 60)
    }

    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    // Howard Hinnant's civil-from-days / days-from-civil.
    static func civil(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func days(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    private static func p2(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// "2026-11-01T21:51:23.123+08:00"
    public static func iso(_ ms: Int64) -> String {
        let local = ms + offsetMs
        let dayN = floorDiv(local, dayMs)
        let rem = local - dayN * dayMs
        let (y, m, d) = civil(dayN)
        let h = rem / 3_600_000, mi = rem / 60000 % 60, s = rem / 1000 % 60, f = rem % 1000
        let fs = f < 10 ? "00\(f)" : (f < 100 ? "0\(f)" : "\(f)")
        return "\(y)-\(p2(m))-\(p2(d))T\(p2(h)):\(p2(mi)):\(p2(s)).\(fs)\(suffix)"
    }

    /// Local calendar day "YYYY-MM-DD" (configured offset) of an instant.
    public static func day(_ ms: Int64) -> String {
        let (y, m, d) = civil(floorDiv(ms + offsetMs, dayMs))
        return "\(y)-\(p2(m))-\(p2(d))"
    }

    /// Instant (epoch ms) of local midnight that starts `day`.
    public static func dayStart(_ day: String) -> Int64? {
        let p = day.split(separator: "-").compactMap { Int64($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        return days(p[0], p[1], p[2]) * dayMs - offsetMs
    }

    public static func addDays(_ day: String, _ n: Int) -> String {
        guard let s = dayStart(day) else { return day }
        return Zone.day(s + Int64(n) * dayMs)
    }

    public static func today() -> String { day(nowMs()) }

    /// Parses an instant. Accepts ISO 8601 with offset ("...Z", "...+08:00"), or a local wall time (configured offset):
    /// "YYYY-MM-DD", "YYYY-MM-DD HH:MM[:SS[.mmm]]", "YYYY-MM-DDTHH:MM..." without offset, or "HH:MM[:SS]" on `onDay` (default today).
    public static func parse(_ raw: String, onDay: String? = nil) -> Int64? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s == "now" { return nowMs() }
        var offset: Int64 = offsetMs
        if s.hasSuffix("Z") { offset = 0; s.removeLast() }
        else if s.count > 6, s.contains("T") || s.count > 16 {
            let tail = s.suffix(6)
            if (tail.first == "+" || tail.first == "-"), tail.dropFirst().count == 5, tail.dropFirst().dropFirst(2).first == ":" {
                let hh = Int64(tail.dropFirst().prefix(2)) ?? 0, mm = Int64(tail.suffix(2)) ?? 0
                offset = (hh * 3600 + mm * 60) * 1000 * (tail.first == "-" ? -1 : 1)
                s.removeLast(6)
            }
        }
        var datePart: String, timePart: String
        if let sep = s.firstIndex(where: { $0 == "T" || $0 == " " }) {
            datePart = String(s[..<sep]); timePart = String(s[s.index(after: sep)...])
        } else if s.contains(":") {
            datePart = onDay ?? today(); timePart = s
        } else {
            datePart = s; timePart = "00:00"
        }
        let dp = datePart.split(separator: "-").compactMap { Int64($0) }
        guard dp.count == 3 else { return nil }
        let secPieces = timePart.split(separator: ".")
        let tp = secPieces[0].split(separator: ":").compactMap { Int64($0) }
        guard (2...3).contains(tp.count), tp[0] < 24, tp[1] < 60 else { return nil }
        var frac: Int64 = 0
        if secPieces.count > 1 {
            let f = String(secPieces[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            frac = Int64(f) ?? 0
        }
        let localMs = days(dp[0], dp[1], dp[2]) * dayMs + tp[0] * 3_600_000 + tp[1] * 60000 + (tp.count > 2 ? tp[2] : 0) * 1000 + frac
        return localMs - offset
    }
}
