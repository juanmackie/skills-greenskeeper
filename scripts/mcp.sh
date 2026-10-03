#!/bin/bash
# Skills Greenskeeper - MCP Server Inventory & Usage
# Inventories every configured MCP server — Claude Code (user, project,
# per-project entries in ~/.claude.json, plugin-bundled .mcp.json), OpenCode
# (global/project opencode.json[c]) and Pi (user/project mcp.json, including
# mcp-adapter.json) — and cross-references REAL usage from session transcripts
# (Claude tool_use entries named mcp__<server>__<tool>, OpenCode skill-style
# <server>_<tool> parts, Pi mcp__<server>__<tool> calls).
#
# Unlike skills, MCP tool schemas live server-side — the greenskeeper does not
# invent token numbers for them. It reports what it can prove: where the
# server is configured, how many distinct tools you've actually called,
# how often, and when last.
#
# Usage:
#   mcp.sh [--weeks N] [--json]

set -euo pipefail

command -v python3 &>/dev/null || { echo "ERROR: python3 required" >&2; exit 1; }

WEEKS=8
JSON_OUTPUT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --weeks) WEEKS="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        -h|--help) echo "Usage: mcp.sh [--weeks N] [--json]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Transcript usage: pre-filter with grep (transcript trees run to GBs) ---
# Only lines containing an mcp__ tool_use name are relevant; only files
# modified inside the lookback window are read at all.
USAGE_TMP=$(mktemp -t janitor-mcp.XXXXXX)
trap 'rm -f "$USAGE_TMP"' EXIT

DAYS=$((WEEKS * 7))
for _proj_root in "${CLAUDE_CONFIG_DIR:-/nonexistent}/projects" "$HOME/.claude/projects" "$HOME"/.claude-account-*/projects; do
    [[ -d "$_proj_root" ]] || continue
    # realpath-dedup roots (~/.claude may symlink to an account dir)
    _rr=$(cd "$_proj_root" 2>/dev/null && pwd -P || echo "$_proj_root")
    case "|${_seen_roots:-}|" in *"|$_rr|"*) continue ;; esac
    _seen_roots="${_seen_roots:-}|$_rr"
    find "$_proj_root" -name "*.jsonl" -type f -mtime "-$DAYS" 2>/dev/null \
        | while IFS= read -r f; do
            LC_ALL=C grep -h '"name":"mcp__' "$f" 2>/dev/null || true
        done >> "$USAGE_TMP"
done

export USAGE_TMP WEEKS JSON_OUTPUT
export CLAUDE_JSON="$HOME/.claude.json"
export PROJECT_MCP="./.mcp.json"
export INSTALLED_PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"
export OPENCODE_SHARE="${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}"
export OPENCODE_GLOBAL_JSON="$HOME/.config/opencode/opencode.json"
export OPENCODE_GLOBAL_JSONC="$HOME/.config/opencode/opencode.jsonc"
export OPENCODE_CUSTOM_JSON="${OPENCODE_CONFIG:-}"
export OPENCODE_PROJECT_JSON="./opencode.json"
export OPENCODE_PROJECT_JSONC="./opencode.jsonc"
export PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
export PI_SESSIONS_ROOT="${PI_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions}"
# Absolute path so the python pass can import jsonc.py regardless of cwd.
# (Importing must not litter the install dir with __pycache__.)
JANITOR_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export JANITOR_SCRIPT_DIR
export PYTHONDONTWRITEBYTECODE=1

python3 <<'PYEOF'
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

# Pin LF on stdout (Windows pipe \r\n translation breaks bash consumers).
sys.stdout.reconfigure(newline="\n")

WEEKS = int(os.environ.get("WEEKS", "8"))
JSON_OUTPUT = os.environ.get("JSON_OUTPUT", "false") == "true"

# --- JSONC reader ------------------------------------------------------------
# OpenCode configs are often .jsonc (comments, trailing commas). The reader
# lives in jsonc.py (same dir as this script) so swipe.sh imports the exact
# same code for removal validation.
sys.path.insert(0, os.environ.get("JANITOR_SCRIPT_DIR", ""))
from jsonc import parse_jsonc

def load_config(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return parse_jsonc(f.read())
    except Exception:
        return None

# --- Inventory ---------------------------------------------------------------
servers = {}  # name -> record; first scope wins, extra scopes appended

def add(name, scope, origin, kind, cfg_file, cfg, pointer=None):
    key = name
    if key in servers:
        if scope not in servers[key]["scopes"]:
            servers[key]["scopes"].append(scope)
        return
    if not isinstance(cfg, dict):
        cfg = {}
    cmd = cfg.get("command", "")
    if isinstance(cmd, list):
        cmd = " ".join(str(x) for x in cmd)
    url = cfg.get("url", "")
    if not isinstance(url, str):
        url = ""
    servers[key] = {
        "name": name,
        "scope": scope,
        "scopes": [scope],
        "kind": kind,        # claude | opencode | pi | plugin
        "cfg": cfg_file,     # config file owning the entry ("" if none)
        "pointer": pointer,   # JSON key path to the entry (opencode/pi)
        "origin": origin,    # human-readable source description
        "transport": cfg.get("type", "stdio"),
        "command": str(cmd)[:120],
        "url": url[:200],
        "enabled": cfg.get("enabled", True) is not False,
    }

cj_path = os.environ.get("CLAUDE_JSON", "")
if cj_path and os.path.isfile(cj_path):
    try:
        cj = json.load(open(cj_path))
    except Exception:
        cj = {}
    for name, cfg in (cj.get("mcpServers") or {}).items():
        add(name, "mcp-user", cj_path, "claude", cj_path, cfg,
            ["mcpServers", name])
    for proj, pdata in (cj.get("projects") or {}).items():
        if not isinstance(pdata, dict):
            continue
        for name, cfg in (pdata.get("mcpServers") or {}).items():
            add(name, "mcp-project", f"{cj_path} [projects -> {proj}]",
                "claude", cj_path, cfg, ["projects", proj, "mcpServers", name])

pm = os.environ.get("PROJECT_MCP", "")
if pm and os.path.isfile(pm):
    try:
        d = json.load(open(pm))
        for name, cfg in (d.get("mcpServers") or {}).items():
            add(name, "mcp-project", os.path.abspath(pm), "claude",
                os.path.abspath(pm), cfg, ["mcpServers", name])
    except Exception:
        pass

# Plugin-bundled MCP servers: <installPath>/.mcp.json
ip = os.environ.get("INSTALLED_PLUGINS_FILE", "")
if ip and os.path.isfile(ip):
    try:
        data = json.load(open(ip))
        plugins = data.get("plugins") if isinstance(data, dict) else None
        for key, instances in (plugins or {}).items():
            pname = key.split("@", 1)[0]
            for inst in instances if isinstance(instances, list) else []:
                path = inst.get("installPath", "") if isinstance(inst, dict) else ""
                mcp_file = os.path.join(path, ".mcp.json")
                if path and os.path.isfile(mcp_file):
                    try:
                        d = json.load(open(mcp_file))
                        for name, cfg in (d.get("mcpServers") or {}).items():
                            add(name, "mcp-plugin", f"plugin:{pname}",
                                "plugin", "", cfg)
                    except Exception:
                        pass
    except Exception:
        pass

# OpenCode MCP servers: global/project opencode.json(c), plus an explicit
# OPENCODE_CONFIG file when set. Configs are often .jsonc — parsed with the
# comment-tolerant reader above (which doubles as the removal validator).
def oc_transport(cfg):
    t = cfg.get("type", "")
    if t in ("local", "stdio"):
        return "stdio"
    if t in ("remote", "http", "streamable-http", "sse"):
        return "http"
    if "command" in cfg:
        return "stdio"
    if "url" in cfg:
        return "http"
    return t or "stdio"

oc_files = [
    (os.environ.get("OPENCODE_GLOBAL_JSON", ""), "mcp-opencode-user"),
    (os.environ.get("OPENCODE_GLOBAL_JSONC", ""), "mcp-opencode-user"),
    (os.environ.get("OPENCODE_CUSTOM_JSON", ""), "mcp-opencode-user"),
    (os.environ.get("OPENCODE_PROJECT_JSON", ""), "mcp-opencode-project"),
    (os.environ.get("OPENCODE_PROJECT_JSONC", ""), "mcp-opencode-project"),
]
for oc_path, oc_scope in oc_files:
    if not oc_path or not os.path.isfile(oc_path):
        continue
    data = load_config(oc_path)
    if not isinstance(data, dict):
        continue
    mcp_cfg = data.get("mcp")
    if not isinstance(mcp_cfg, dict):
        continue
    mcp_ptr = ["mcp"]
    if isinstance(mcp_cfg.get("servers"), dict) and not any(
            isinstance(v, dict) and ("command" in v or "url" in v or "type" in v)
            for v in mcp_cfg.values()):
        # Non-standard nesting ({"mcp": {"servers": {...}}}): descend so a
        # pseudo-server called "servers" is never inventoried — deleting it
        # would remove every real server at once.
        mcp_cfg = mcp_cfg["servers"]
        mcp_ptr = ["mcp", "servers"]
    for name, cfg in (mcp_cfg.items() if isinstance(mcp_cfg, dict) else []):
        if not isinstance(cfg, dict):
            cfg = {}
        cfg = dict(cfg)
        cfg["type"] = oc_transport(cfg)
        add(name, oc_scope, oc_path, "opencode", oc_path, cfg, mcp_ptr + [name])

# Pi MCP servers: user/project mcp.json plus mcp-adapter.json (present when
# the pi-mcp-adapter extension replaces the built-in MCP support — those
# entries are still real context cost, flagged by origin).
pi_agent = os.environ.get("PI_AGENT_DIR", "")
pi_files = []
if pi_agent:
    pi_files.append((os.path.join(pi_agent, "mcp.json"), "mcp-pi-user", False))
    pi_files.append((os.path.join(pi_agent, "mcp-adapter.json"), "mcp-pi-user", True))
pi_files.append(("./.pi/mcp.json", "mcp-pi-project", False))
for pi_path, pi_scope, via_adapter in pi_files:
    if not os.path.isfile(pi_path):
        continue
    data = load_config(pi_path)
    if not isinstance(data, dict):
        continue
    for name, cfg in ((data.get("mcpServers") or {}).items()):
        if not isinstance(cfg, dict):
            cfg = {}
        cfg = dict(cfg)
        cfg["type"] = oc_transport(cfg)
        origin = os.path.abspath(pi_path)
        if via_adapter:
            origin += " (mcp-adapter extension)"
        add(name, pi_scope, origin, "pi", os.path.abspath(pi_path), cfg,
            ["mcpServers", name])

# --- Usage from transcripts --------------------------------------------------
NAME_RX = re.compile(r'"name":"mcp__([^_"][^"]*?)__([^"]+)"')
TS_RX = re.compile(r'"timestamp":"([0-9T:.\-]+)')

calls = defaultdict(int)          # server -> total calls
tools = defaultdict(set)          # server -> distinct tools called
last_used = {}                    # server -> iso ts

usage_tmp = os.environ.get("USAGE_TMP", "")
if usage_tmp and os.path.isfile(usage_tmp):
    with open(usage_tmp, errors="replace") as f:
        for line in f:
            names = NAME_RX.findall(line)
            if not names:
                continue
            ts_m = TS_RX.search(line)
            ts = ts_m.group(1)[:10] if ts_m else ""
            for server, tool in names:
                calls[server] += 1
                tools[server].add(tool)
                if ts and ts > last_used.get(server, ""):
                    last_used[server] = ts

# --- OpenCode usage from the SQLite session store (read-only) ---
# MCP tools surface as <server>_<tool> parts. Window by session time first
# so multi-GB stores stay fast; match servers by normalized prefix after.
import sqlite3 as _sqlite3
oc_calls = defaultdict(int)
oc_tools = defaultdict(set)
oc_last = {}
oc_db = os.path.join(os.environ.get("OPENCODE_SHARE", ""), "opencode.db")
if oc_db and os.path.isfile(oc_db):
    try:
        _con = _sqlite3.connect(oc_db)
        _cur = _con.cursor()
        _cutoff_ms = int((datetime.now(timezone.utc) - timedelta(weeks=WEEKS)).timestamp() * 1000)
        _cur.execute("SELECT id FROM session WHERE time_updated >= ?", (_cutoff_ms,))
        _ids = [r[0] for r in _cur.fetchall()]
        for _i in range(0, len(_ids), 500):
            _chunk = _ids[_i:_i + 500]
            _q = ("SELECT data, time_updated FROM part WHERE session_id IN (%s)"
                  % ",".join("?" * len(_chunk)))
            for _data, _tms in _cur.execute(_q, _chunk):
                try:
                    _d = json.loads(_data)
                except Exception:
                    continue
                if not isinstance(_d, dict):
                    continue
                _tool = _d.get("tool")
                if not isinstance(_tool, str) or not _tool:
                    continue
                try:
                    _dt = datetime.fromtimestamp(int(_tms) / 1000, tz=timezone.utc)
                except Exception:
                    continue
                _day = _dt.strftime("%Y-%m-%d")
                oc_calls[_tool] += 1
                oc_tools[_tool].add(_tool)
                if _day > oc_last.get(_tool, ""):
                    oc_last[_tool] = _day
        _con.close()
    except Exception as _e:
        print("WARNING: OpenCode MCP usage skipped (%s)" % _e, file=sys.stderr)

# --- Pi usage from session JSONL trees ---
# Pi registers MCP tools as mcp__<server>__<tool>. Parse only lines
# mentioning mcp__ from files inside the lookback window.
pi_calls = defaultdict(int)
pi_tools = defaultdict(set)
pi_last = {}
pi_root = os.environ.get("PI_SESSIONS_ROOT", "")
PI_MCP_RX = re.compile(r'"(?:toolName|name)"\s*:\s*"(mcp__[^"]+)"')
if pi_root and os.path.isdir(pi_root):
    try:
        _cut_day = (datetime.now(timezone.utc) - timedelta(weeks=WEEKS)).strftime("%Y-%m-%d")
        for _root, _dirs, _files in os.walk(pi_root):
            for _fn in _files:
                if not _fn.endswith(".jsonl"):
                    continue
                _fp = os.path.join(_root, _fn)
                try:
                    if datetime.fromtimestamp(os.path.getmtime(_fp), tz=timezone.utc).strftime("%Y-%m-%d") < _cut_day:
                        continue
                except OSError:
                    continue
                try:
                    _f = open(_fp, encoding="utf-8", errors="replace")
                except OSError:
                    continue
                with _f:
                    for _line in _f:
                        if "mcp__" not in _line:
                            continue
                        _names = PI_MCP_RX.findall(_line)
                        if not _names:
                            continue
                        _ts_m = re.search(r'"timestamp"\s*:\s*"([0-9T:.\-]+)', _line)
                        _day = _ts_m.group(1)[:10] if _ts_m else ""
                        if not _day or _day < _cut_day:
                            continue
                        for _full in _names:
                            _rest = _full[5:]
                            _bits = _rest.split("__")
                            _srv = _bits[0]
                            _tl = "__".join(_bits[1:]) if len(_bits) > 1 else "(namespace)"
                            pi_calls[_srv] += 1
                            pi_tools[_srv].add(_tl)
                            if _day > pi_last.get(_srv, ""):
                                pi_last[_srv] = _day
    except Exception as _e:
        print("WARNING: Pi MCP usage skipped (%s)" % _e, file=sys.stderr)

def _norm(s):
    return s.lower().replace("-", "_")

def _prefix_usage(cfg_name, use_calls, use_tools, use_last):
    # Exact normalized match, else a normalized <server>_ prefix hit (covers
    # OpenCode <server>_<tool> parts and Pi's -/_-folded server names).
    key = _norm(cfg_name)
    if cfg_name in use_calls:
        return cfg_name
    for used in use_calls:
        u = _norm(used)
        if u == key or u.startswith(key + "_") or u.startswith(key + "-"):
            return used
    low = key
    for used in use_calls:
        u = _norm(used)
        if low in u or u in low:
            return used
    return None

# Transcript names may differ from config names (plugin MCP servers get
# prefixed/namespaced). Match loosely: exact, else substring either way.
def usage_for(cfg_name):
    if cfg_name in calls:
        return cfg_name
    low = cfg_name.lower().replace("-", "_")
    for used in calls:
        u = used.lower()
        if low in u or u in low:
            return used
    return None

rows = []
for s in servers.values():
    kind = s.get("kind", "claude")
    if kind == "opencode":
        hit = _prefix_usage(s["name"], oc_calls, oc_tools, oc_last)
        n_calls = oc_calls.get(hit, 0) if hit else 0
        n_tools = len(oc_tools.get(hit, ())) if hit else 0
        lu = oc_last.get(hit, "never") if hit else "never"
    elif kind == "pi":
        hit = _prefix_usage(s["name"], pi_calls, pi_tools, pi_last)
        n_calls = pi_calls.get(hit, 0) if hit else 0
        n_tools = len(pi_tools.get(hit, ())) if hit else 0
        lu = pi_last.get(hit, "never") if hit else "never"
    else:
        hit = usage_for(s["name"])
        n_calls = calls.get(hit, 0)
        n_tools = len(tools.get(hit, ()))
        lu = last_used.get(hit, "never")
    # Disabled servers load nothing — never "unused waste".
    if not s.get("enabled", True):
        n_calls, n_tools, lu = 0, 0, "disabled"
    rows.append({
        **{k: v for k, v in s.items() if k != "scopes"},
        "scope": ",".join(sorted(s["scopes"])),
        "calls": n_calls,
        "distinct_tools_used": n_tools,
        "last_used": lu,
    })

# Servers seen in transcripts but not in any config (removed or session-scoped)
configured_hits = {usage_for(s["name"]) for s in servers.values()}
orphans = [
    {"name": u, "scope": "transcript-only", "origin": "(not in any config)",
     "kind": "transcript", "cfg": "", "pointer": None, "enabled": True,
     "transport": "?", "command": "", "url": "",
     "calls": calls[u], "distinct_tools_used": len(tools[u]),
     "last_used": last_used.get(u, "never")}
    for u in sorted(calls) if u not in configured_hits
]

rows.sort(key=lambda r: (r["calls"], r["last_used"]))

if JSON_OUTPUT:
    print(json.dumps({
        "period_weeks": WEEKS,
        "configured": len(rows),
        "unused": sum(1 for r in rows if r["calls"] == 0),
        "servers": rows,
        "transcript_only": orphans,
    }, indent=2))
    sys.exit(0)

print("=== Skills Greenskeeper - MCP Servers ===")
print(f"Usage window: last {WEEKS} weeks of session transcripts")
print()
if not rows and not orphans:
    print("No MCP servers configured.")
    sys.exit(0)

print(f"  {'Server':<28} {'Scope':<18} {'Calls':>6} {'Tools':>6} {'Last Used':<11} Origin")
print(f"  {'─'*28} {'─'*18} {'─'*6} {'─'*6} {'─'*11} {'─'*24}")
for r in rows:
    print(f"  {r['name'][:28]:<28} {r['scope'][:18]:<18} {r['calls']:>6} {r['distinct_tools_used']:>6} {r['last_used']:<11} {r['origin'][:44]}")
print()
unused = [r for r in rows if r["calls"] == 0 and r.get("enabled", True)]
if unused:
    print(f"--- Unused in {WEEKS} weeks ({len(unused)}) ---")
    for r in unused:
        print(f"  {r['name']} ({r['scope']}) - configured in {r['origin'][:60]}")
    print()
    print("  Every connected server loads its tool schemas into context.")
    print("  Consider removing unused entries (or /janitor-swipe to triage).")
if orphans:
    print(f"--- Seen in transcripts, not configured now ({len(orphans)}) ---")
    for r in orphans[:8]:
        print(f"  {r['name']} - {r['calls']} calls, last {r['last_used']}")
PYEOF
