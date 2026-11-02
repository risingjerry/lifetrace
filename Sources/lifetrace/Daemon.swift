import AppKit
import ApplicationServices
import LifetraceCore

// Widely used SPI (yabai, Hammerspoon, AltTab): AX window element -> CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let browserBundles: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.apple.Safari",
    "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser", "company.thebrowser.dia",
    "com.microsoft.edgemac", "com.brave.Browser",
]

func axCopy(_ e: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue().onAX(notification as String, element)
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon { Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue().onInput(type, event) }
    return Unmanaged.passUnretained(event)
}

/// Event-driven recorder. Everything runs on the main thread; the process sleeps in the run loop
/// until the OS delivers a notification. The only timers are the idle deadline (see `scheduleIdle`),
/// the title throttle and an optional pause expiry; layer 4 adds a one-shot minute flush armed only by input,
/// layer 5 one-shot content timers armed only by focus/AX changes.
final class Daemon {
    let paths: Paths
    let cfg: Config
    let journal: Journal
    let seg: Segmenter
    let axForcedOff: Bool
    var axTrusted = false
    var axOK: Bool { axTrusted && cfg.ax && !axForcedOff }

    var locked = false, asleep = false, displayAsleep = false
    var paused = false, pausedUntil: Int64?
    var away: Bool { locked || asleep || displayAsleep || paused }

    var idle = false
    var idleSinceMs: Int64 = 0
    var idleTimer: DispatchSourceTimer?
    var pauseTimer: DispatchSourceTimer?

    var observer: AXObserver?
    var observedPid: pid_t = 0
    var observedWindow: AXUIElement?
    var lastFocus: FocusCtx?
    var lastTitleCheck: Double = 0
    var titlePending = false
    var noWebArea: Set<pid_t> = []
    var sources: [DispatchSourceSignal] = []
    var lockFD: Int32 = -1

    // Layer 4: input counts (listen-only event tap; counts only).
    var tap: CFMachPort?
    var segInput = InputCounts()        // since the last event fed to the segmenter
    var minuteInput = InputCounts()     // since the last activity.minute
    var minuteStartMs: Int64 = 0
    var minuteTimer: DispatchSourceTimer?
    var pbCount = 0
    var inputOK: Bool { tap != nil }

    lazy var content = ContentReader(self)

    init(paths: Paths, cfg: Config) {
        self.paths = paths; self.cfg = cfg
        journal = Journal(paths)
        seg = Segmenter(glanceS: cfg.glanceS)
        axForcedOff = ProcessInfo.processInfo.environment["LIFETRACE_NO_AX"] == "1"
    }

    func now() -> Int64 { Zone.nowMs() }

    /// Set by `lifetrace _probe-content`: print records instead of journaling them.
    var probeOut: ((Event) -> Void)?

    func emit(_ type: String, _ fields: [(String, J)] = [], ts: Int64? = nil) {
        if let probeOut { probeOut(Event(ts: ts ?? now(), type: type, fields)); return }
        if inputOK { syncInput() }
        append(seg.feed(Event(ts: ts ?? now(), type: type, fields)))
    }

    /// Journals records; a failed write is counted and surfaced in state.json / `lifetrace status`.
    func append(_ evs: [Event]) {
        let before = journal.failed
        for e in evs { journal.append(e) }
        if journal.failed != before {
            FileHandle.standardError.write("lifetrace: write failed: \(journal.lastError ?? "?")\n".data(using: .utf8)!)
            writeState()
        }
    }

    // MARK: lifecycle

    func run() -> Never {
        paths.ensure()
        lockFD = open(paths.lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            FileHandle.standardError.write("lifetrace daemon already running\n".data(using: .utf8)!)
            exit(3)
        }
        setpriority(PRIO_PROCESS, 0, 10)
        append(Log.recovery(paths, glanceS: cfg.glanceS))

        axTrusted = AXIsProcessTrusted()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        startTap()
        emit("recorder.start", [("pid", .i(Int64(getpid()))), ("version", .s(lifetraceVersion)), ("ax", .b(axOK)),
                                ("ax_trusted", .b(axTrusted)), ("input", .b(inputOK)), ("config", cfg.json)])
        // LIFETRACE_SMOKE_IGNORE_LOCK=1: test hook for smoke runs on a locked screen (never set by the LaunchAgent).
        if ProcessInfo.processInfo.environment["LIFETRACE_SMOKE_IGNORE_LOCK"] != "1",
           let d = CGSessionCopyCurrentDictionary() as? [String: Any], (d["CGSSessionScreenIsLocked"] as? Bool) == true {
            locked = true; emit("presence.lock")
        }
        applyControl(by: "start")
        writeState()
        registerNotifications()
        registerSignals()
        if !away { announceFront(reason: "start") }
        scheduleIdle()
        CFRunLoopRun()
        exit(0)
    }

    func stop(reason: String) -> Never {
        flushMinute()
        endIdle(reason: "away")
        emit("recorder.stop", [("reason", .s(reason))])
        writeState(running: false)
        exit(0)
    }

    func writeState(running: Bool = true) {
        let j: J = .o([("v", .s(schemaVersion)), ("pid", .i(Int64(getpid()))), ("running", .b(running)),
                       ("version", .s(lifetraceVersion)), ("started", .s(Zone.iso(startedMs))), ("updated", .s(Zone.iso(now()))),
                       ("ax", .b(axOK)), ("ax_trusted", .b(axTrusted)), ("ax_forced_off", .b(axForcedOff || !cfg.ax)),
                       ("input", .b(inputOK)), ("input_listen_access", .b(CGPreflightListenEventAccess())),
                       ("paused", .b(paused)), ("paused_until", pausedUntil.map { .s(Zone.iso($0)) } ?? .null),
                       ("write_errors", .i(Int64(journal.failed))), ("last_write_error", journal.lastError.map { .s($0) } ?? .null),
                       ("config", cfg.json)])
        try? (j.encode() + "\n").write(toFile: paths.state, atomically: true, encoding: .utf8)
    }
    let startedMs = Zone.nowMs()

    func registerNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [unowned self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if !self.away { self.announce(app, reason: "activate") }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [unowned self] _ in
            self.goAway { self.asleep = true; self.emit("presence.sleep") }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            self.comeBack { self.asleep = false; self.displayAsleep = false; self.emit("presence.wake") }
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [unowned self] _ in
            self.goAway { self.displayAsleep = true; self.emit("presence.display_sleep") }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            self.comeBack { self.displayAsleep = false; self.emit("presence.display_wake") }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            self.goAway { self.locked = true; self.emit("presence.lock", [("why", .s("session_switch"))]) }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            self.comeBack { self.locked = false; self.emit("presence.unlock", [("why", .s("session_switch"))]) }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [unowned self] _ in
            if !self.locked { self.goAway { self.locked = true; self.emit("presence.lock") } }
        }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [unowned self] _ in
            if self.locked { self.comeBack { self.locked = false; self.emit("presence.unlock") } }
        }
        // Posted when the Accessibility (TCC) list changes; trust flips a moment later.
        dn.addObserver(forName: .init("com.apple.accessibility.api"), object: nil, queue: .main) { [unowned self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.recheckPermission() }
        }
    }

    func registerSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGUSR1] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [unowned self] in
                if sig == SIGUSR1 { self.applyControl(by: "cli"); self.writeState() } else { self.stop(reason: "signal") }
            }
            s.resume()
            sources.append(s)
        }
    }

    func recheckPermission() {
        let t = AXIsProcessTrusted()
        guard t != axTrusted else { return }
        axTrusted = t
        if !axOK { dropObserver() }
        if !inputOK { startTap(); if inputOK && away { CGEvent.tapEnable(tap: tap!, enable: false) } }
        emit("recorder.perm", [("ax", .b(axOK)), ("ax_trusted", .b(axTrusted))])
        writeState()
        if !away { announceFront(reason: "perm") }
    }

    // MARK: presence

    func goAway(_ change: () -> Void) {
        let wasAway = away
        if !wasAway { flushMinute(); endIdle(reason: "away") }
        change()
        if away {
            idleTimer?.cancel(); idleTimer = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            // Drop the AX observer (and its content subscriptions) so coming back re-attaches even to the same app.
            dropObserver()
        }
    }

    func comeBack(_ change: () -> Void) {
        let wasAway = away
        change()
        if wasAway && !away {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            pbCount = NSPasteboard.general.changeCount
            announceFront(reason: "resume")
            scheduleIdle()
        }
    }

    /// pause/resume via control.json (written by `lifetrace pause|resume`, then SIGUSR1).
    func applyControl(by: String) {
        let j = (try? String(contentsOfFile: paths.control, encoding: .utf8)).flatMap { J.parse($0) }
        var want = j?["paused"]?.bool ?? false
        let until = j?["until"]?.str.flatMap { Zone.parse($0) }
        if want, let until, until <= now() { want = false }
        pauseTimer?.cancel(); pauseTimer = nil
        if want {
            // A repeated pause replaces the deadline (e.g. a timed pause made indefinite).
            let changed = !paused || until != pausedUntil
            pausedUntil = until
            if changed { goAway { paused = true; emit("recorder.pause", until.map { [("until", .s(Zone.iso($0)))] } ?? []) } }
        } else if !want && paused {
            pausedUntil = nil
            comeBack { paused = false; emit("recorder.resume", [("by", .s(by))]) }
        }
        if paused, let until = pausedUntil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(Int(max(0, until - now()))), leeway: .seconds(1))
            t.setEventHandler { [unowned self] in
                try? "{\"paused\":false}\n".write(toFile: self.paths.control, atomically: true, encoding: .utf8)
                self.applyControl(by: "timer"); self.writeState()
            }
            t.resume(); pauseTimer = t
        }
    }

    // MARK: idle
    //
    // Not a fixed poll: while the user is active we sleep until the earliest moment idleness could
    // begin (last input + threshold), typically one wake-up per minute. While idle we check every
    // idle_poll_s (default 3 s) so idle_end is accurate to a few seconds. No timer at all while
    // locked/asleep/paused.

    func secondsSinceInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func checkIdle() {
        guard !away else { return }
        let secs = secondsSinceInput()
        let lastInput = now() - Int64(secs * 1000)
        if !idle, secs >= cfg.idleThresholdS {
            idle = true; idleSinceMs = lastInput
            emit("presence.idle_start", [("threshold_s", .d(cfg.idleThresholdS)), ("detected", .s(Zone.iso(now())))], ts: lastInput)
        } else if idle, lastInput > idleSinceMs + 500 {
            endIdle(reason: "input", at: lastInput)
        }
    }

    func endIdle(reason: String, at: Int64? = nil) {
        guard idle else { return }
        let t = at ?? now()
        idle = false
        emit("presence.idle_end", [("idle_s", .d(Double(t - idleSinceMs) / 1000)), ("reason", .s(reason))], ts: t)
    }

    func scheduleIdle() {
        idleTimer?.cancel(); idleTimer = nil
        guard !away else { return }
        checkIdle()
        let delay = idle ? cfg.idlePollS : max(1, cfg.idleThresholdS - secondsSinceInput() + 0.25)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(idle ? 1000 : 2000))
        t.setEventHandler { [unowned self] in self.scheduleIdle() }
        t.resume()
        idleTimer = t
    }

    // MARK: focus

    func announceFront(reason: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        announce(app, reason: reason)
    }

    func announce(_ app: NSRunningApplication, reason: String) {
        guard !away else { return }
        checkIdle()
        observe(app.processIdentifier)
        let c = readCtx(app.processIdentifier, app: app.localizedName, bundle: app.bundleIdentifier)
        lastFocus = c
        emit("focus.app", c.fields + [("reason", .s(reason))])
        content.focusChanged()
    }

    func readCtx(_ pid: pid_t, app: String?, bundle: String?) -> FocusCtx {
        var c = FocusCtx(app: app, bundle: bundle, pid: Int(pid))
        guard axOK else { return c }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        guard let wObj = axCopy(el, kAXFocusedWindowAttribute), CFGetTypeID(wObj) == AXUIElementGetTypeID() else { return c }
        let w = wObj as! AXUIElement
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(w, &wid) == .success, wid != 0 { c.win = Int(wid) }
        c.title = FocusCtx.normalizeTitle(axCopy(w, kAXTitleAttribute) as? String)
        if let d = axCopy(w, kAXDocumentAttribute) as? String {
            if d.hasPrefix("http://") || d.hasPrefix("https://") { c.url = d }
            else if let u = URL(string: d), u.isFileURL { c.doc = u.path }
        }
        if c.url == nil, let b = bundle, browserBundles.contains(b) { c.url = browserURL(pid, window: w, bundle: b) }
        return c.redacted()
    }

    /// AXWebArea.AXURL via a bounded search (works where the browser exposes web content, e.g. Safari).
    /// Chromium browsers usually do not unless an assistive app enabled it; remembered per pid so the
    /// search is not repeated. Optional AppleScript fallback (config browser_applescript) needs the
    /// user to allow Automation for each browser.
    func browserURL(_ pid: pid_t, window: AXUIElement, bundle: String) -> String? {
        if !noWebArea.contains(pid) {
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var seen = 0
            while !queue.isEmpty && seen < 150 {
                let (e, d) = queue.removeFirst(); seen += 1
                if (axCopy(e, kAXRoleAttribute) as? String) == "AXWebArea" {
                    if let u = axCopy(e, kAXURLAttribute) { return (u as? URL)?.absoluteString ?? (u as? String) }
                    break
                }
                if d < 8, let kids = axCopy(e, kAXChildrenAttribute) as? [AXUIElement] { queue += kids.map { ($0, d + 1) } }
            }
            noWebArea.insert(pid)
        }
        return cfg.browserAppleScript ? appleScriptURL(bundle) : nil
    }

    func appleScriptURL(_ bundle: String) -> String? {
        let tab = bundle.contains("Safari") ? "current tab" : "active tab"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application id \"\(bundle)\" to get URL of \(tab) of front window"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(1.5)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.hasPrefix("http") ?? false) ? s : nil
    }

    func dropObserver() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil; observedPid = 0; observedWindow = nil
        content.reset()
    }

    func observe(_ pid: pid_t) {
        guard axOK else { return }
        if pid != observedPid {
            dropObserver()
            var o: AXObserver?
            guard AXObserverCreate(pid, axCallback, &o) == .success, let o else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            AXObserverAddNotification(o, app, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            observer = o; observedPid = pid
            content.attach(o, app)
        }
        watchFocusedWindow()
    }

    func watchFocusedWindow() {
        guard let o = observer else { return }
        let app = AXUIElementCreateApplication(observedPid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let old = observedWindow { AXObserverRemoveNotification(o, old, kAXTitleChangedNotification as CFString) }
        observedWindow = nil
        guard let wObj = axCopy(app, kAXFocusedWindowAttribute), CFGetTypeID(wObj) == AXUIElementGetTypeID() else { return }
        let w = wObj as! AXUIElement
        if AXObserverAddNotification(o, w, kAXTitleChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success {
            observedWindow = w
        }
    }

    func onAX(_ name: String, _ element: AXUIElement) {
        guard !away, axOK else { return }
        if name == kAXValueChangedNotification as String { content.changed(); return }
        if name == kAXSelectedTextChangedNotification as String { content.selectionChanged(); return }
        if name == kAXFocusedWindowChangedNotification as String {
            watchFocusedWindow()
            emitIfChanged("focus.window")
        } else if name == kAXTitleChangedNotification as String {
            // Throttle: some apps animate titles many times per second.
            let t = Date().timeIntervalSince1970
            if t - lastTitleCheck >= cfg.titleThrottleS {
                lastTitleCheck = t
                emitIfChanged("focus.title")
            } else if !titlePending {
                titlePending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (lastTitleCheck + cfg.titleThrottleS - t)) { [weak self] in
                    guard let self else { return }
                    self.titlePending = false; self.lastTitleCheck = Date().timeIntervalSince1970
                    if !self.away { self.emitIfChanged("focus.title") }
                }
            }
        }
    }

    func emitIfChanged(_ type: String) {
        guard observedPid != 0, let prev = lastFocus, prev.pid == Int(observedPid) else { return }
        let c = readCtx(observedPid, app: prev.app, bundle: prev.bundle)
        guard c != prev else { if type == "focus.title" { content.changed() }; return }
        checkIdle()
        lastFocus = c
        emit(c.win != prev.win ? "focus.window" : type, c.fields)
        if c.key != prev.key { content.focusChanged() } else { content.changed() }
    }

    // MARK: input counts (layer 4)
    //
    // A listen-only CGEventTap for key-down, mouse-down and scroll events only (no mouse moves). The
    // callback just bumps integers. Copies are the pasteboard changeCount delta, read only when a
    // record is written. A one-shot timer at the next minute boundary is armed by the first input of
    // a minute, so idle minutes cost nothing and produce no record. The tap is disabled while away.

    func startTap() {
        guard cfg.inputCounts, tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        tap = t
        pbCount = NSPasteboard.general.changeCount
    }

    func onInput(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, !away { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !away else { return }
        var c = InputCounts()
        switch type {
        case .keyDown:
            if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            c.keys = 1
            // kVK_ANSI_V with Command = paste. Only this one chord is checked; no key is recorded.
            if e.getIntegerValueField(.keyboardEventKeycode) == 9 && e.flags.contains(.maskCommand) { c.pastes = 1 }
        case .scrollWheel:
            c.scrollPx = Int(abs(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) + abs(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)))
            if e.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 { c.scrolls = 1 }
        default:
            c.clicks = 1
        }
        segInput = segInput + c
        minuteInput = minuteInput + c
        if minuteTimer == nil {
            let n = now()
            minuteStartMs = n / 60_000 * 60_000
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(Int(minuteStartMs + 60_000 - n)), leeway: .seconds(1))
            t.setEventHandler { [unowned self] in self.flushMinute() }
            t.resume(); minuteTimer = t
        }
    }

    /// Moves pending counts (and the pasteboard delta) into the open segment.
    func syncInput() {
        let pb = NSPasteboard.general.changeCount
        if pb != pbCount {
            let d = max(0, pb - pbCount); pbCount = pb
            segInput.copies += d; minuteInput.copies += d
        }
        if !segInput.isZero { seg.addInput(segInput); segInput = InputCounts() } else { seg.addInput(InputCounts()) }
    }

    func flushMinute() {
        if minuteTimer == nil { minuteStartMs = now() / 60_000 * 60_000 }   // only a pasteboard change pending
        minuteTimer?.cancel(); minuteTimer = nil
        guard inputOK else { return }
        syncInput()
        guard !minuteInput.isZero else { return }
        let c = minuteInput
        minuteInput = InputCounts()
        emit("activity.minute", c.fields, ts: minuteStartMs)
    }
}
