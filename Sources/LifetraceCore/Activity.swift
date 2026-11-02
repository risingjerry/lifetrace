import Foundation

/// Layer 4: input counts. Never key identity or content.
public struct InputCounts: Equatable {
    public var keys = 0, clicks = 0, scrolls = 0, scrollPx = 0, copies = 0, pastes = 0

    public init(keys: Int = 0, clicks: Int = 0, scrolls: Int = 0, scrollPx: Int = 0, copies: Int = 0, pastes: Int = 0) {
        self.keys = keys; self.clicks = clicks; self.scrolls = scrolls; self.scrollPx = scrollPx
        self.copies = copies; self.pastes = pastes
    }

    public init(event e: Event) {
        func n(_ k: String) -> Int { Int(e.int(k) ?? 0) }
        self.init(keys: n("keys"), clicks: n("clicks"), scrolls: n("scrolls"), scrollPx: n("scroll_px"),
                  copies: n("copies"), pastes: n("pastes"))
    }

    public var isZero: Bool { self == InputCounts() }

    public static func + (a: InputCounts, b: InputCounts) -> InputCounts {
        InputCounts(keys: a.keys + b.keys, clicks: a.clicks + b.clicks, scrolls: a.scrolls + b.scrolls,
                    scrollPx: a.scrollPx + b.scrollPx, copies: a.copies + b.copies, pastes: a.pastes + b.pastes)
    }

    public var fields: [(String, J)] {
        [("keys", .i(Int64(keys))), ("clicks", .i(Int64(clicks))), ("scrolls", .i(Int64(scrolls))),
         ("scroll_px", .i(Int64(scrollPx))), ("copies", .i(Int64(copies))), ("pastes", .i(Int64(pastes)))]
    }
}

/// Masks strings that look like credentials before any text is written.
public enum Redact {
    static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----|$)"#, "[REDACTED:private_key]"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}"#, "[REDACTED:jwt]"),
        (#"\bsk-[A-Za-z0-9_\-]{16,}"#, "[REDACTED:key]"),
        (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, "[REDACTED:key]"),
        (#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, "[REDACTED:key]"),
        (#"\bAIza[0-9A-Za-z_\-]{35}"#, "[REDACTED:key]"),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "[REDACTED:key]"),
        // Bearer tokens in full (same rule as lifetrace_sources/core.py), with or without "Authorization:".
        (#"(?i)\b((?:authorization["']?\s*[:=]\s*["']?)?bearer\s+)[^\s,"';]+["']?"#, "$1[REDACTED]"),
        // key = value / key: value — keep the key, mask the value; a quoted value is masked whole.
        (#"(?i)\b((?:[a-z0-9]+[_-])*(?:password|passwd|pwd|passcode|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|auth(?:orization)?)["']?\s*[:=]\s*(?:(?:Bearer|Basic|Token)\s+)?)(?:"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|[^\s"',;&]+)"#, "$1[REDACTED]"),
        (#"((?:密码|口令|密钥|令牌|验证码)\s*[:：=]\s*)(?:"[^"\n]*"|'[^'\n]*'|“[^”\n]*”|\S+)"#, "$1[REDACTED]"),
        (#"\b[0-9a-fA-F]{32,}\b"#, "[REDACTED:hex]"),
        // Personal identifiers: mainland mobile numbers and e-mail addresses.
        (#"(?<![0-9])1[3-9][0-9]{9}(?![0-9])"#, "[REDACTED:phone]"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[REDACTED:email]"),
        (#"(?<![A-Za-z0-9+_\-])(?=[A-Za-z0-9+_\-]*[0-9])(?=[A-Za-z0-9+_\-]*[a-z])(?=[A-Za-z0-9+_\-]*[A-Z])[A-Za-z0-9+_\-]{32,}={0,2}"#, "[REDACTED:token]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func apply(_ text: String) -> String {
        var s = text
        for (re, tpl) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tpl)
        }
        return s
    }

    /// Query/fragment parameter names whose values are credentials (compared per `_`/`-`/`.` separated word).
    static let urlSecretWords: Set<String> = ["token", "key", "apikey", "secret", "password", "passwd", "pwd", "pass", "auth",
        "authorization", "code", "sig", "signature", "session", "sessionid", "sid", "credential", "credentials", "otp", "jwt",
        "ticket", "nonce", "hash", "assertion", "saml", "samlresponse", "accesstoken", "refreshtoken", "idtoken"]

    /// Parameter names that carry personal data (contact, location, account ids) rather than credentials.
    static let urlPersonalWords: Set<String> = ["phone", "mobile", "tel", "email", "mail", "lat", "lng", "lon", "flat", "flng",
        "tlat", "tlng", "latitude", "longitude", "geo", "location", "coord", "coords", "uid", "openid", "unionid", "userid", "idcard"]

    static func isSecretParam(_ name: String) -> Bool {
        let n = name.lowercased()
        if ["token", "secret", "passw", "session", "signature", "credential", "apikey", "api_key", "access_key",
            "phone", "mobile", "email", "latitude", "longitude", "open_id", "openid", "unionid", "union_id", "user_id", "userid",
            "id_card", "idcard"].contains(where: n.contains) { return true }
        return n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains {
            urlSecretWords.contains(String($0)) || urlPersonalWords.contains(String($0))
        }
    }

    /// A URL safe to store: no user/password, credential-like query and fragment parameters replaced by
    /// `REDACTED`, then the text rules applied to what is left.
    public static func url(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else {
            // Unparseable: drop anything that looks like userinfo, then the text rules.
            return apply(raw.replacingOccurrences(of: #"(?<=://)[^/@\s]*@"#, with: "", options: .regularExpression))
        }
        c.user = nil; c.password = nil
        if let items = c.percentEncodedQueryItems {
            c.percentEncodedQueryItems = items.map { isSecretParam($0.name) && $0.value != nil ? URLQueryItem(name: $0.name, value: "REDACTED") : $0 }
        }
        if let f = c.percentEncodedFragment, f.contains("=") {
            // OAuth implicit flow etc. put credentials in the fragment as key=value pairs.
            c.percentEncodedFragment = f.split(separator: "&", omittingEmptySubsequences: false).map { kv -> String in
                let pair = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 && isSecretParam(String(pair[0])) ? String(pair[0]) + "=REDACTED" : String(kv)
            }.joined(separator: "&")
        }
        return apply(c.string ?? raw)
    }
}

public enum TextCap {
    /// First `maxBytes` of UTF-8, cut on a character boundary.
    public static func utf8Prefix(_ s: String, _ maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var out = "", n = 0
        for ch in s {
            let c = ch.utf8.count
            if n + c > maxBytes { break }
            out.append(ch); n += c
        }
        return out
    }

    /// FNV-1a 64, hex. Stable across runs (unlike Swift's Hasher).
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}
