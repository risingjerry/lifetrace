import Foundation

/// Minimal ordered JSON value. Key order is preserved on output so records stay readable.
public indirect enum J: Equatable {
    case s(String), i(Int64), d(Double), b(Bool), null
    case o([(String, J)]), a([J])

    public static func == (l: J, r: J) -> Bool { l.encode() == r.encode() }

    public func encode() -> String {
        var out = ""
        write(&out)
        return out
    }

    func write(_ out: inout String) {
        switch self {
        case .s(let v): J.esc(v, &out)
        case .i(let v): out += String(v)
        case .d(let v): out += J.num(v)
        case .b(let v): out += v ? "true" : "false"
        case .null: out += "null"
        case .a(let xs):
            out += "["
            for (n, x) in xs.enumerated() { if n > 0 { out += "," }; x.write(&out) }
            out += "]"
        case .o(let kv):
            out += "{"
            for (n, (k, v)) in kv.enumerated() { if n > 0 { out += "," }; J.esc(k, &out); out += ":"; v.write(&out) }
            out += "}"
        }
    }

    /// Up to 3 decimals, no trailing zeros.
    static func num(_ v: Double) -> String {
        guard v.isFinite else { return "null" }
        let r = (v * 1000).rounded() / 1000
        if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
        var s = String(format: "%.3f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func esc(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }

    /// From JSONSerialization output (object keys sorted for determinism).
    public static func from(_ any: Any?) -> J {
        guard let any else { return .null }
        switch any {
        case let s as String: return .s(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .b(n.boolValue) }
            if CFNumberIsFloatType(n) { return .d(n.doubleValue) }
            return .i(n.int64Value)
        case let a as [Any]: return .a(a.map { from($0) })
        case let d as [String: Any]: return .o(d.keys.sorted().map { ($0, from(d[$0])) })
        default: return .null
        }
    }

    public static func parse(_ text: String) -> J? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return from(any)
    }

    public subscript(_ key: String) -> J? {
        if case .o(let kv) = self { return kv.first(where: { $0.0 == key })?.1 }
        return nil
    }

    public var str: String? { if case .s(let v) = self { return v }; return nil }
    public var int: Int64? {
        switch self { case .i(let v): return v; case .d(let v): return Int64(v); default: return nil }
    }
    public var dbl: Double? {
        switch self { case .i(let v): return Double(v); case .d(let v): return v; default: return nil }
    }
    public var bool: Bool? { if case .b(let v) = self { return v }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
}

public extension J {
    /// Convenience: optional string -> .s or .null
    static func opt(_ s: String?) -> J { s.map { .s($0) } ?? .null }
    static func opt(_ i: Int?) -> J { i.map { .i(Int64($0)) } ?? .null }
}
