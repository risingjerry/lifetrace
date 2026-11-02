import Foundation

/// Machine-readable act.v1 spec (`lifetrace schema --json`). SCHEMA.md is the prose version;
/// a unit test keeps the two in sync (every type and field here must appear in SCHEMA.md).
public enum Schema {
    public typealias Field = (name: String, type: String, desc: String)

    public static let common: [Field] = [
        ("v", "string", "schema version, always \"act.v1\""),
        ("ts", "string", "ISO 8601 with ms in the configured UTC offset (utc_offset), e.g. 2026-11-01T21:51:23.123+08:00; decides the day file"),
        ("type", "string", "event type, layer.name"),
    ]

    static let ctx: [Field] = [
        ("app", "string", "app display name"), ("bundle", "string", "bundle id"), ("pid", "int", "process id"),
        ("win", "int", "CGWindowID of the focused window (needs Accessibility)"),
        ("title", "string", "focused window title, spinner glyphs stripped (needs Accessibility)"),
        ("doc", "string", "document file path from AXDocument (needs Accessibility)"),
        ("url", "string", "browser page URL (AX or opt-in AppleScript)"), ("host", "string", "url host without www."),
        ("seg", "string", "segment id this focus event belongs to"),
    ]

    public static let types: [(type: String, desc: String, fields: [Field])] = [
        ("recorder.start", "daemon started", [("pid", "int", "daemon pid"), ("version", "string", "lifetrace version"),
            ("ax", "bool", "Accessibility usable (window/title/doc/url level)"), ("ax_trusted", "bool", "OS reports Accessibility granted"),
            ("config", "object", "effective config")]),
        ("recorder.stop", "daemon stopped", [("reason", "string", "signal | crash (recovered at next start, ts = last recorded instant)")]),
        ("recorder.pause", "recording paused by user", [("until", "string", "ISO time the pause auto-ends, absent = until resume")]),
        ("recorder.resume", "recording resumed", [("by", "string", "cli | timer")]),
        ("recorder.perm", "permission state changed", [("ax", "bool", "Accessibility usable"), ("ax_trusted", "bool", "OS reports Accessibility granted")]),
        ("presence.lock", "screen locked (or fast user switch away)", [("why", "string", "session_switch for fast user switching, else absent")]),
        ("presence.unlock", "screen unlocked", [("why", "string", "session_switch for fast user switching, else absent")]),
        ("presence.sleep", "system going to sleep", []),
        ("presence.wake", "system woke", []),
        ("presence.display_sleep", "displays slept", []),
        ("presence.display_wake", "displays woke", []),
        ("presence.idle_start", "no keyboard/mouse input for idle_threshold_s; ts = instant of the last input",
            [("threshold_s", "number", "idle threshold used"), ("detected", "string", "ISO time the daemon noticed")]),
        ("presence.idle_end", "input resumed (or idle cut short by lock/sleep/pause/stop)",
            [("idle_s", "number", "length of the idle period"), ("reason", "string", "input | away")]),
        ("focus.app", "frontmost app changed (or re-announced after start/unlock/wake/resume)",
            ctx + [("reason", "string", "activate | start | resume | perm")]),
        ("focus.window", "focused window changed inside the frontmost app", ctx),
        ("focus.title", "window title / document / URL changed in the focused window (throttled to title_throttle_s)", ctx),
        ("segment.end", "a focus segment (same app + window + doc/url) ended",
            [("seg", "string", "segment id; same as the focus.* events inside it"),
             ("part", "int", "1-based piece number when a segment crosses local midnight"), ("parts", "int", "number of pieces"),
             ("start", "string", "ISO start of this piece"), ("end", "string", "ISO end of this piece"),
             ("dur_s", "number", "end - start, seconds"), ("active_s", "number", "dur_s - idle_s"),
             ("idle_s", "number", "seconds of idle inside the piece"), ("glance", "bool", "whole segment shorter than glance_s (2 s)"),
             ("reason", "string", "switch | window | doc | url | lock | sleep | display | pause | stop | crash | midnight"),
             ("titles", "int", "distinct window titles seen in the segment (counted up to 256)"),
             ("titles_capped", "bool", "true when more than 256 distinct titles were seen; titles is then a lower bound"),
             ("revised", "bool", "correction of an earlier segment.end with the same seg/part (back-dated idle); the last one wins")] + Array(ctx.dropLast()) +
            input),
        ("activity.minute", "input counts for one local clock minute; written only for minutes with input; ts = start of the minute",
            [("seg", "string", "segment open when the minute was flushed")] + input),
        ("content.snapshot", "visible text of the focused window via Accessibility (no images), after focus is stable 3 s; re-read at most every 60 s on change",
            [("seg", "string", "segment id"), ("app", "string", "app display name"), ("bundle", "string", "bundle id"),
             ("hash", "string", "FNV-1a 64 hash of text; identical text is stored once"),
             ("text", "string", "redacted text, at most 4 KB: selection, focused element, then window content; absent when repeat"),
             ("repeat", "bool", "same text was stored recently (look up by hash); text omitted"),
             ("chars", "int", "characters in text"), ("truncated", "bool", "text was cut to 4 KB"),
             ("progress", "number", "0..1 vertical position of the main scroll area, when available"),
             ("nodes", "int", "Accessibility elements visited"), ("read_ms", "number", "time spent reading"),
             ("why", "string", "stable | change")]),
        ("content.selection", "selected text changed (debounced 1.5 s)",
            [("seg", "string", "segment id"), ("bundle", "string", "bundle id"),
             ("text", "string", "redacted selected text, at most 2 KB"), ("chars", "int", "characters selected")]),
        ("source.<source>.<kind>", "record from an external reader in sources/<source>/YYYY-MM-DD.jsonl (see SOURCES.md)",
            [("source", "string", "source name"), ("id", "string", "dedupe id, unique within source")]),
    ]

    static let input: [Field] = [
        ("keys", "int", "key presses (no autorepeat); never which key"), ("clicks", "int", "mouse/trackpad button presses"),
        ("scrolls", "int", "scroll gesture events (momentum excluded)"), ("scroll_px", "int", "scrolled distance in points, incl. momentum"),
        ("copies", "int", "pasteboard writes (changeCount delta)"), ("pastes", "int", "Cmd+V presses"),
    ]

    public static var json: J {
        func fj(_ f: [Field]) -> J { .a(f.map { .o([("name", .s($0.name)), ("type", .s($0.type)), ("desc", .s($0.desc))]) }) }
        return .o([("v", .s(schemaVersion)), ("query", .s("schema")), ("common", fj(common)),
                   ("types", .a(types.map { .o([("type", .s($0.type)), ("desc", .s($0.desc)), ("fields", fj($0.fields))]) })),
                   ("doc", .s("Full prose: SCHEMA.md (lifetrace schema)"))])
    }
}
