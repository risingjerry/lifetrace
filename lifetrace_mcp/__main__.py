"""lifetrace MCP server (stdio): thin wrapper that shells out to `lifetrace ... --json`.

Run: python3 -m lifetrace_mcp   (needs the `mcp` package)
Binary lookup: $LIFETRACE_BIN, then `lifetrace` on PATH, ~/.local/bin/lifetrace, ./.build/release/lifetrace.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

try:  # mcp >= 2
    from mcp.server.mcpserver import MCPServer
except ImportError:  # mcp 1.x
    from mcp.server.fastmcp import FastMCP as MCPServer

REPO = Path(__file__).resolve().parent.parent


def binary() -> str:
    for cand in (os.environ.get("LIFETRACE_BIN"), shutil.which("lifetrace"),
                 str(Path.home() / ".local/bin/lifetrace"), str(REPO / ".build/release/lifetrace")):
        if cand and os.access(cand, os.X_OK):
            return cand
    raise RuntimeError("lifetrace binary not found; run `make install` or set LIFETRACE_BIN")


def call(*args: str) -> dict:
    proc = subprocess.run([binary(), *args, "--json"], capture_output=True, text=True, timeout=60)
    text = proc.stdout.strip()
    if not text:
        return {"v": "act.v1", "error": proc.stderr.strip() or f"exit {proc.returncode}"}
    return json.loads(text)


mcp = MCPServer("lifetrace")


@mcp.tool(name="lifetrace_status", description="Is the activity recorder running, its memory/CPU, permission level (window or app only), today's event count. Call first.")
def status() -> dict:
    return call("status")


@mcp.tool(name="lifetrace_schema", description="The act.v1 data schema: every event type and field, units and meaning.")
def schema() -> dict:
    return call("schema")


@mcp.tool(name="lifetrace_timeline", description="Ordered focus blocks and away gaps for one local day (YYYY-MM-DD, 'today', 'yesterday'; days use the configured utc_offset). raw=true lists every segment unmerged; sources=true interleaves external source records (browser history etc.).")
def timeline(day: str = "today", raw: bool = False, sources: bool = False) -> dict:
    return call("timeline", day, *(["--raw"] if raw else []), *(["--sources"] if sources else []))


@mcp.tool(name="lifetrace_at", description="What was happening at one instant: '14:30' (today, local), '2026-11-01 14:30', or ISO 8601 with offset.")
def at(time: str) -> dict:
    return call("at", time)


@mcp.tool(name="lifetrace_stats", description="Time per app/domain/window, active time by hour, app switches, interruptions, longest focus. day=YYYY-MM-DD (default today); week=true covers the 7 days ending on day.")
def stats(day: str = "today", week: bool = False, top: int = 15) -> dict:
    return call("stats", *(["--week", day] if week else ["--day", day]), "--top", str(top))


@mcp.tool(name="lifetrace_events", description="Raw act.v1 events for drill-down: by segment id (from timeline 'segs'), time range (from/to, local wall time or ISO), and/or type prefix (e.g. 'focus.', 'content.', 'activity.'). source=NAME returns that external source's records instead.")
def events(seg: str = "", start: str = "", end: str = "", type: str = "", source: str = "", limit: int = 200) -> dict:
    args = ["events", "--limit", str(limit)]
    for flag, val in (("--seg", seg), ("--from", start), ("--to", end), ("--type", type), ("--source", source)):
        if val:
            args += [flag, val]
    return call(*args)


@mcp.tool(name="lifetrace_search", description="Full-text search over text seen on screen (content snapshots, selections), window titles/URLs and external source records. All terms must match (substring, any language). Newest first; each hit has ts, kind, source, seg or id, snippet. Filters: start/end (local wall time or ISO), source (external source name, or 'act' for the recorder's own data).")
def search(query: str, start: str = "", end: str = "", source: str = "", limit: int = 50) -> dict:
    args = ["search", query, "--limit", str(limit)]
    for flag, val in (("--from", start), ("--to", end), ("--source", source)):
        if val:
            args += [flag, val]
    return call(*args)


if __name__ == "__main__":
    mcp.run()
