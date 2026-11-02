import AppKit
import ApplicationServices
import LifetraceCore

/// Layer 5: what text was on screen, read through Accessibility (never pixels).
///
/// Event-driven and bounded:
/// - a read happens 3 s after focus settles (`focusChanged`), then at most once per 60 s, and only after the
///   app reported a value/title change (`changed`). After the first change notification the value-changed
///   subscription is dropped until the next read, so a busy terminal wakes us once per minute, not per update;
/// - each read walks the focused window breadth-first with hard limits (nodes, depth, 30 ms);
/// - secure text fields and everything under them are never read (nor a focused element inside one);
///   excluded bundles and private browser windows are never read;
/// - memory is bounded too: text is read through bounded ranges (`maxReadChars`), children in bounded pages,
///   and only hashes are kept for dedupe;
/// - each text is redacted before it is cut, the result capped at 4 KB and stored only when its hash changed.
final class ContentReader {
    static let stableS = 3.0, rereadS = 60.0, selectionQuietS = 1.5
    static let maxBytes = 4096, maxNodes = 400, maxDepth = 40, budgetMs = 30.0
    /// UTF-16 units read from one element at most (selection, visible text); a full value only when it is no longer.
    static let maxReadChars = 4096, maxAncestors = 12
    /// Not read at all / read but not descended into (controls whose children are not content).
    static let skip: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuBarItem", "AXApplication", "AXScrollBar", "AXSplitter"]
    static let leaf: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXButton", "AXImage",
                                    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXIncrementor",
                                    "AXValueIndicator", "AXDisclosureTriangle", "AXProgressIndicator"]
    static let privateMarkers = ["Private Browsing", "Incognito", "InPrivate", "无痕", "隐私浏览", "隐身"]

    unowned let d: Daemon
    var observer: AXObserver?
    var appEl: AXUIElement?
    var valueArmed = false
    var readTimer: DispatchSourceTimer?
    var selTimer: DispatchSourceTimer?
    var lastRead: Double = 0
    var lastSelNotify: Double = 0
    var segHash: (String, String)?          // (seg, hash) of the last snapshot
    var recent: [String] = []               // hashes of recently stored texts
    var lastSelection: Int?                 // hash of the last stored selection
    var privateVerdict: (win: Int?, isPrivate: Bool)?   // from the last full read of a browser window

    init(_ d: Daemon) { self.d = d }

    var enabled: Bool { d.cfg.content && d.axOK && !d.away && !d.cfg.contentExcluded(d.lastFocus?.bundle) }
    func clock() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: triggers

    /// New AX observer for the frontmost app.
    func attach(_ o: AXObserver, _ app: AXUIElement) {
        reset()
        observer = o; appEl = app
        guard d.cfg.content, !d.cfg.contentExcluded(NSRunningApplication(processIdentifier: d.observedPid)?.bundleIdentifier) else { return }
        AXObserverAddNotification(o, app, kAXSelectedTextChangedNotification as CFString, Unmanaged.passUnretained(d).toOpaque())
    }

    func reset() {
        readTimer?.cancel(); readTimer = nil
        selTimer?.cancel(); selTimer = nil
        setValueArmed(false)
        observer = nil; appEl = nil
    }

    func focusChanged() {
        lastSelection = nil
        schedule(after: ContentReader.stableS, why: "stable")
    }

    /// A value or title changed in the focused app.
    func changed() {
        setValueArmed(false)
        guard readTimer == nil else { return }
        schedule(after: max(ContentReader.stableS, lastRead + ContentReader.rereadS - clock()), why: "change")
    }

    func selectionChanged() {
        lastSelNotify = clock()
        guard selTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + ContentReader.selectionQuietS, repeating: ContentReader.selectionQuietS, leeway: .milliseconds(300))
        t.setEventHandler { [unowned self] in
            guard self.clock() - self.lastSelNotify >= ContentReader.selectionQuietS - 0.2 else { return }   // still changing
            self.selTimer?.cancel(); self.selTimer = nil
            self.readSelection()
        }
        t.resume(); selTimer = t
    }

    func schedule(after s: Double, why: String) {
        readTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + s, leeway: .milliseconds(500))
        t.setEventHandler { [unowned self] in
            self.readTimer?.cancel(); self.readTimer = nil
            self.snapshot(why: why)
            if self.enabled { self.setValueArmed(true) }
        }
        t.resume(); readTimer = t
    }

    func setValueArmed(_ on: Bool) {
        guard on != valueArmed, let o = observer, let app = appEl else { valueArmed = on && observer != nil; return }
        if on { AXObserverAddNotification(o, app, kAXValueChangedNotification as CFString, Unmanaged.passUnretained(d).toOpaque()) }
        else { AXObserverRemoveNotification(o, app, kAXValueChangedNotification as CFString) }
        valueArmed = on
    }

    // MARK: reading

    func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = axCopy(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func isSecure(_ e: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return (axCopy(e, kAXRoleAttribute) as? String) == secure || (axCopy(e, kAXSubroleAttribute) as? String) == secure
    }

    /// The focused element or one of its ancestors (up to the window) is a secure text field.
    func insideSecure(_ e: AXUIElement) -> Bool {
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXParentAttribute] as CFArray
        let secure = kAXSecureTextFieldSubrole as String
        var cur: AXUIElement? = e
        for _ in 0..<ContentReader.maxAncestors {
            guard let c = cur else { return false }
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(c, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success,
                  let v = vals as? [AnyObject], v.count == 3 else { return isSecure(c) }
            let role = v[0] as? String
            if role == secure || (v[1] as? String) == secure { return true }
            if role == kAXWindowRole as String || role == kAXApplicationRole as String { return false }
            cur = CFGetTypeID(v[2]) == AXUIElementGetTypeID() ? (v[2] as! AXUIElement) : nil
        }
        return false
    }

    /// Best-effort private/incognito browser window. A full read (`texts` given) decides from the title and the
    /// window's own text and remembers the verdict for that window; a selection (no texts) uses the title and that
    /// verdict, and is skipped while the window has not been read yet.
    func isPrivate(_ f: FocusCtx, texts: [String]?) -> Bool {
        guard let b = f.bundle, browserBundles.contains(b) else { return false }
        let hit = ([f.title ?? ""] + (texts ?? [])).contains { t in ContentReader.privateMarkers.contains { t.contains($0) } }
        if texts != nil { privateVerdict = (f.win, hit); return hit }
        if hit { return true }
        guard let v = privateVerdict, v.win != nil, v.win == f.win else { return true }
        return v.isPrivate
    }

    /// `range` of the element's text, clipped to `maxReadChars`, without copying the whole value.
    func string(_ e: AXUIElement, _ loc: Int, _ len: Int) -> String? {
        var r = CFRange(location: loc, length: min(len, ContentReader.maxReadChars))
        guard r.length > 0, let range = AXValueCreate(.cfRange, &r) else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, range, &v) == .success else { return nil }
        return v as? String
    }

    func cfRange(_ e: AXUIElement, _ attr: String) -> CFRange? {
        guard let r = axCopy(e, attr), CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(r as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Visible text of a text area/field: the visible character range when the element reports one,
    /// otherwise the start of its value (bounded).
    func visibleText(_ e: AXUIElement) -> String? {
        if let range = cfRange(e, kAXVisibleCharacterRangeAttribute), range.length > 0,
           let s = string(e, range.location, range.length) { return s }
        if let n = axCopy(e, kAXNumberOfCharactersAttribute) as? Int, n > ContentReader.maxReadChars { return string(e, 0, n) }
        return axCopy(e, kAXValueAttribute) as? String
    }

    /// Selected text (bounded) and the selection's full length. Elements that report neither a selected range
    /// nor a small character count are not read (the copy could be arbitrarily large).
    func selectedText(_ e: AXUIElement) -> (String, Int)? {
        if let range = cfRange(e, kAXSelectedTextRangeAttribute) {
            guard range.length > 0, let s = string(e, range.location, range.length) else { return nil }
            return (s, range.length)
        }
        guard let n = axCopy(e, kAXNumberOfCharactersAttribute) as? Int, n <= ContentReader.maxReadChars,
              let s = axCopy(e, kAXSelectedTextAttribute) as? String else { return nil }
        return (s, s.utf16.count)
    }

    func snapshot(why: String, anyWindow: Bool = false) {
        guard enabled, d.observedPid != 0, let f = d.lastFocus, f.pid == Int(d.observedPid) else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsedMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
        let app = AXUIElementCreateApplication(d.observedPid)
        // anyWindow (probe only): first window, for apps that are not frontmost.
        guard let win = anyWindow ? (axCopy(app, kAXWindowsAttribute) as? [AXUIElement])?.first : element(app, kAXFocusedWindowAttribute)
        else { return }
        lastRead = clock()

        var parts: [String] = []
        var bytes = 0, dropped = false
        var seen = Set<Int>()
        func add(_ s: String?, cap: Int = 1500) {
            guard let s, case let t = s.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 2, seen.insert(t.hashValue).inserted else { return }
            guard bytes < ContentReader.maxBytes else { dropped = true; return }
            // Redact the whole candidate, then cut: a secret cut in half would no longer match the rules.
            let p = TextCap.utf8Prefix(Redact.apply(t), cap)
            parts.append(p); bytes += p.utf8.count + 1
        }
        let focused = element(app, kAXFocusedUIElementAttribute)
        let focusedSecure = focused.map(insideSecure) ?? false
        if let fe = focused, !focusedSecure {
            add(selectedText(fe)?.0, cap: 1000)
            add(visibleText(fe))
        }

        // Breadth-first walk of the window. One IPC per node for role/subrole and the visible rows/children
        // (bounded by the screen); plain children only when those are absent, fetched in a bounded page.
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, "AXVisibleRows", "AXVisibleChildren"] as CFArray
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var i = 0, nodes = 0
        var progress: Double?
        while i < queue.count, nodes < ContentReader.maxNodes, elapsedMs() < ContentReader.budgetMs {
            let (e, depth) = queue[i]; i += 1; nodes += 1
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &vals) == .success,
                  let v = vals as? [AnyObject], v.count == 4 else { continue }
            let role = v[0] as? String ?? "", sub = v[1] as? String ?? ""
            if role == kAXSecureTextFieldSubrole as String || sub == kAXSecureTextFieldSubrole as String { continue }
            if ContentReader.skip.contains(role) { continue }
            switch role {
            case kAXStaticTextRole:
                add(axCopy(e, kAXValueAttribute) as? String, cap: 600)
            case kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole:
                if let fe = focused, CFEqual(fe, e) { break }
                guard elapsedMs() < ContentReader.budgetMs else { break }
                add(visibleText(e))
            case kAXScrollAreaRole where progress == nil:
                if let bar = element(e, kAXVerticalScrollBarAttribute), let p = axCopy(bar, kAXValueAttribute) as? Double { progress = p }
            default: break
            }
            let room = ContentReader.maxNodes - queue.count
            guard depth < ContentReader.maxDepth, !ContentReader.leaf.contains(role), room > 0,
                  elapsedMs() < ContentReader.budgetMs else { continue }
            var kids = [v[2], v[3]].lazy.compactMap { $0 as? [AXUIElement] }.first { !$0.isEmpty } ?? []
            if kids.isEmpty {
                var arr: CFArray?
                if AXUIElementCopyAttributeValues(e, kAXChildrenAttribute as CFString, 0, room, &arr) == .success { kids = arr as? [AXUIElement] ?? [] }
            }
            queue += kids.prefix(room).map { ($0, depth + 1) }
        }

        // Best-effort private/incognito browser windows: never store their content.
        if isPrivate(f, texts: parts) { return }

        let joined = parts.joined(separator: "\n")
        guard !joined.isEmpty else { return }
        let text = TextCap.utf8Prefix(joined, ContentReader.maxBytes)
        let hash = TextCap.hash(text)
        let segId = d.seg.openSeg ?? ""
        if let (s, h) = segHash, s == segId, h == hash { return }
        segHash = (segId, hash)
        let isRepeat = recent.contains(hash)
        if !isRepeat { recent.append(hash); if recent.count > 64 { recent.removeFirst() } }
        var fields: [(String, J)] = [("app", .opt(f.app)), ("bundle", .opt(f.bundle)), ("hash", .s(hash))]
        fields += isRepeat ? [("repeat", .b(true))] : [("text", .s(text))]
        fields += [("chars", .i(Int64(text.count))), ("truncated", .b(dropped || text.utf8.count < joined.utf8.count)),
                   ("progress", progress.map { .d($0) } ?? .null), ("nodes", .i(Int64(nodes))),
                   ("read_ms", .d(elapsedMs())), ("why", .s(why))]
        d.emit("content.snapshot", fields.filter { !$0.1.isNull })
    }

    func readSelection() {
        guard enabled, d.observedPid != 0, let f = d.lastFocus, f.pid == Int(d.observedPid), !isPrivate(f, texts: nil) else { return }
        let app = AXUIElementCreateApplication(d.observedPid)
        guard let fe = element(app, kAXFocusedUIElementAttribute), !insideSecure(fe),
              let (raw, total) = selectedText(fe) else { return }
        let sel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sel.count >= 2, sel.hashValue != lastSelection else { return }
        lastSelection = sel.hashValue
        // Redact the bounded read first, then cut to 2 KB.
        let text = TextCap.utf8Prefix(Redact.apply(sel), 2048)
        let chars = total > raw.utf16.count ? total : sel.count
        d.emit("content.selection", [("bundle", .opt(f.bundle)), ("text", .s(text)), ("chars", .i(Int64(chars)))])
    }
}
