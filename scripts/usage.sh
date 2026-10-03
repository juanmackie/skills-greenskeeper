#!/bin/bash
# Skills Greenskeeper - Usage Tracking
# Parses conversation history to track skill invocation frequency

set -euo pipefail

command -v python3 &>/dev/null || { echo "ERROR: python3 required" >&2; exit 1; }

# --- Defaults ---
WEEKS=4
JSON_OUTPUT=false
DATA_DIR="$(cd "$(dirname "$0")/.." && pwd)/data"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --weeks) WEEKS="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        -h|--help) echo "Usage: usage.sh [--weeks N] [--json]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Export for Python ---
export WEEKS JSON_OUTPUT DATA_DIR HISTORY_FILE

# --- Load platform paths ---
source "$(dirname "$0")/paths.sh"

# --- Paths ---
USER_SKILLS="$CLAUDE_USER_SKILLS"
PROJECT_SKILLS="$CLAUDE_PROJECT_SKILLS"

# Resolve the conversation-history file. Order: explicit CLAUDE_CONFIG_DIR,
# the standard install location, then multi-account config dirs. The old
# code hardcoded a single non-standard path, so standard installs found no
# history and every skill was reported as "never used".
HISTORY_FILE=""
for _cand in \
    "${CLAUDE_CONFIG_DIR:-/nonexistent}/history.jsonl" \
    "$HOME/.claude/history.jsonl" \
    "$HOME"/.claude-account-*/history.jsonl; do
    if [[ -f "$_cand" ]]; then
        HISTORY_FILE="$_cand"
        break
    fi
done

if [[ -z "$HISTORY_FILE" ]]; then
    echo "WARNING: Claude history file not found (looked in \$CLAUDE_CONFIG_DIR, ~/.claude, ~/.claude-account-*)" >&2
    echo "Usage tracking requires Claude Code conversation history; counts will show as 0." >&2
    # Don't exit - still scan skills for inventory
fi

# --- Ensure data dir exists ---
mkdir -p "$DATA_DIR"

# --- Collect skills and their descriptions ---
export SKILLS_TMPFILE=$(mktemp)
trap 'rm -f "$SKILLS_TMPFILE"' EXIT

collect_skills() {
    local dir="$1"
    local scope="$2"
    local namespace="${3:-}"
    [[ -d "$dir" ]] || return 0

    for skill_dir in "$dir"/*/; do
        [[ -d "$skill_dir" ]] || continue
        local name
        name=$(basename "$skill_dir")

        # Skip self
        [[ "$name" == "skills-greenskeeper" ]] && continue

        local skill_file=""
        [[ -f "$skill_dir/SKILL.md" ]] && skill_file="$skill_dir/SKILL.md"
        [[ -f "$skill_dir/Skill.md" ]] && skill_file="$skill_dir/Skill.md"
        [[ -z "$skill_file" ]] && continue
        [[ ! -e "$skill_file" ]] && continue

        local desc
        desc=$(extract_description "$skill_file" | tr '[:upper:]' '[:lower:]')

        # Qualified name matches Claude's invocation syntax for plugin skills
        # (e.g. "marketing-skills:image"). Slash-command matching below uses
        # this exact form to detect plugin-skill invocations in history.
        local display_name="$name"
        [[ -n "$namespace" ]] && display_name="${namespace}:${name}"

        # Realpath lets python dedupe one physical skill reachable from two
        # roots (e.g. ~/.claude/skills/foo -> ~/.agents/skills/foo symlink),
        # which previously produced duplicate rows in every report.
        local realpath
        realpath=$(cd "$skill_dir" 2>/dev/null && pwd -P || echo "$skill_dir")

        printf '%s\t%s\t%s\t%s\n' "$scope" "$display_name" "$realpath" "$desc" >> "$SKILLS_TMPFILE"
    done
}

# Scan all harnesses (Claude Code + Codex + OpenCode + Pi + plugins + sources)
_usage_scan() {
    local _scope="$2"
    [[ "$3" != "claude" ]] && _scope="$3-$2"
    collect_skills "$1" "$_scope" "$4"
}
for_each_skill_dir _usage_scan

# --- Transcript-based Skill invocations (v1.7) ---
# Session transcripts record every Skill tool_use — including skills Claude
# auto-triggered, which the slash-command history can't see. Pre-filter with
# grep (transcript trees run to GBs) over files inside the lookback window.
export SKILL_CALLS_TMP=$(mktemp)
export OPENCODE_CALLS_TMP=$(mktemp)
export PI_CALLS_TMP=$(mktemp)
export OPENCODE_SHARE="${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}"
export PI_SESSIONS_ROOT="${PI_CODING_AGENT_SESSION_DIR:-$PI_AGENT_DIR/sessions}"
trap 'rm -f "$SKILLS_TMPFILE" "$SKILL_CALLS_TMP" "$OPENCODE_CALLS_TMP" "$PI_CALLS_TMP"' EXIT
# Soft warnings (inventories still run, counts stay 0): only warn when the
# harness actually has skills registered, so Claude-only installs stay quiet.
if [[ "$HAS_OPENCODE" == "true" && ! -f "$OPENCODE_SHARE/opencode.db" && ! -d "$OPENCODE_SHARE/project" ]]; then
    echo "WARNING: OpenCode skills present but no session store found under $OPENCODE_SHARE" >&2
    echo "OpenCode usage counts will show as 0." >&2
fi
if [[ "$HAS_PI" == "true" && ! -d "$PI_SESSIONS_ROOT" ]]; then
    echo "WARNING: Pi skills present but no sessions found under $PI_SESSIONS_ROOT" >&2
    echo "Pi usage counts will show as 0." >&2
fi
_DAYS=$(( WEEKS * 7 ))
_seen_tr_roots=""
for _proj_root in "${CLAUDE_CONFIG_DIR:-/nonexistent}/projects" "$HOME/.claude/projects" "$HOME"/.claude-account-*/projects; do
    [[ -d "$_proj_root" ]] || continue
    _rr=$(cd "$_proj_root" 2>/dev/null && pwd -P || echo "$_proj_root")
    case "|$_seen_tr_roots|" in *"|$_rr|"*) continue ;; esac
    _seen_tr_roots="$_seen_tr_roots|$_rr"
    find "$_proj_root" -name "*.jsonl" -type f -mtime "-$_DAYS" 2>/dev/null \
        | while IFS= read -r _tf; do
            LC_ALL=C grep -h '"name":"Skill"' "$_tf" 2>/dev/null || true
        done >> "$SKILL_CALLS_TMP"
done

# --- OpenCode + Pi skill invocations ---
# OpenCode: sessions live in a SQLite store (opencode.db; SELECT-only access,
# windowed by session time so multi-GB stores stay fast), with a best-effort
# regex pass over legacy JSON storage. Pi: session JSONL trees, where a skill
# load is a `read` tool call on .../skills/<name>/SKILL.md and a forced load
# is a `/skill:<name>` user message. Both stages emit name<TAB>YYYY-MM-DD.
python3 << 'PYEOF'
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
# Pin LF on stdout (Windows pipe \r\n translation breaks bash consumers).
sys.stdout.reconfigure(newline="\n")

WEEKS = int(os.environ.get("WEEKS", "4"))
now = datetime.now(timezone.utc)
cutoff = now - timedelta(weeks=WEEKS)
cutoff_day = cutoff.strftime("%Y-%m-%d")

# --- OpenCode: SQLite session store (read-only queries, no writes) ---
oc_out = os.environ.get("OPENCODE_CALLS_TMP", "")
oc_lines = []
oc_db = os.path.join(os.environ.get("OPENCODE_SHARE", ""), "opencode.db")
if oc_db and os.path.isfile(oc_db):
    try:
        con = sqlite3.connect(oc_db)
        cur = con.cursor()
        cutoff_ms = int(cutoff.timestamp() * 1000)
        cur.execute("SELECT id FROM session WHERE time_updated >= ?",
                    (cutoff_ms,))
        ids = [r[0] for r in cur.fetchall()]
        for i in range(0, len(ids), 500):
            chunk = ids[i:i + 500]
            q = ("SELECT data, time_updated FROM part "
                 "WHERE session_id IN (%s) AND "
                 "(data LIKE '%%\"tool\":\"skill\"%%' OR "
                 "data LIKE '%%\"tool\": \"skill\"%%')" % ",".join("?" * len(chunk)))
            for data, tms in cur.execute(q, chunk):
                try:
                    d = json.loads(data)
                except Exception:
                    continue
                if not isinstance(d, dict) or d.get("tool") != "skill":
                    continue
                try:
                    name = ((d.get("state") or {}).get("input") or {}).get("name")
                except Exception:
                    name = None
                if not name:
                    continue
                try:
                    dt = datetime.fromtimestamp(int(tms) / 1000, tz=timezone.utc)
                except Exception:
                    continue
                if dt < cutoff:
                    continue
                oc_lines.append("%s\t%s" % (name, dt.strftime("%Y-%m-%d")))
        con.close()
    except Exception as e:
        print("WARNING: OpenCode usage skipped (%s)" % e, file=sys.stderr)
# Legacy JSON storage (pre-SQLite installs): schema-agnostic heuristic —
# count "name" values on lines that record a skill tool call, dated by file
# mtime. Only the documented project/*/storage layout is read.
oc_proj = os.path.join(os.environ.get("OPENCODE_SHARE", ""), "project")
if os.path.isdir(oc_proj):
    rx_tool = re.compile(r'"tool"\s*:\s*"skill"')
    rx_name = re.compile(r'"name"\s*:\s*"([A-Za-z0-9][A-Za-z0-9_-]*)"')
    for root, _dirs, files in os.walk(oc_proj):
        for fn in files:
            if not fn.endswith(".json"):
                continue
            fp = os.path.join(root, fn)
            try:
                mt = datetime.fromtimestamp(os.path.getmtime(fp), tz=timezone.utc)
            except OSError:
                continue
            if mt < cutoff:
                continue
            try:
                with open(fp, encoding="utf-8", errors="replace") as f:
                    txt = f.read(4_000_000)
            except OSError:
                continue
            if '"skill"' not in txt:
                continue
            day = mt.strftime("%Y-%m-%d")
            for line in txt.splitlines():
                if rx_tool.search(line):
                    for m in rx_name.finditer(line):
                        oc_lines.append("%s\t%s" % (m.group(1), day))
if oc_out:
    with open(oc_out, "w", newline="\n") as f:
        f.write("\n".join(oc_lines) + ("\n" if oc_lines else ""))

# --- Pi: session JSONL trees ---
pi_out = os.environ.get("PI_CALLS_TMP", "")
pi_lines = []
pi_root = os.environ.get("PI_SESSIONS_ROOT", "")
SKILL_RX = re.compile(r"[/\\]skills[/\\]([^/\\]+)[/\\]SKILL\.md\s*$", re.I)
FORCE_RX = re.compile(r"/skill:([A-Za-z0-9][A-Za-z0-9_-]*)")
if pi_root and os.path.isdir(pi_root):
    try:
        for root, _dirs, files in os.walk(pi_root):
            for fn in files:
                if not fn.endswith(".jsonl"):
                    continue
                fp = os.path.join(root, fn)
                try:
                    if datetime.fromtimestamp(os.path.getmtime(fp), tz=timezone.utc) < cutoff:
                        continue
                except OSError:
                    continue
                try:
                    f = open(fp, encoding="utf-8", errors="replace")
                except OSError:
                    continue
                with f:
                    for line in f:
                        if "SKILL.md" not in line and "/skill:" not in line:
                            continue
                        try:
                            e = json.loads(line)
                        except Exception:
                            continue
                        if e.get("type") != "message":
                            continue
                        ts = (e.get("timestamp") or "")[:10]
                        if not ts or ts < cutoff_day:
                            continue
                        m = e.get("message") or {}
                        content = m.get("content")
                        if not isinstance(content, list):
                            continue
                        if m.get("role") == "assistant":
                            for item in content:
                                if not isinstance(item, dict):
                                    continue
                                if item.get("type") != "toolCall" or item.get("name") != "read":
                                    continue
                                args = item.get("arguments") or {}
                                p = args.get("path") or args.get("filePath") or ""
                                sm = SKILL_RX.search(p)
                                if sm:
                                    pi_lines.append("%s\t%s" % (sm.group(1), ts))
                        elif m.get("role") == "user":
                            for item in content:
                                if not isinstance(item, dict):
                                    continue
                                for fm in FORCE_RX.finditer(item.get("text") or ""):
                                    pi_lines.append("%s\t%s" % (fm.group(1), ts))
    except Exception as e:
        print("WARNING: Pi usage skipped (%s)" % e, file=sys.stderr)
if pi_out:
    with open(pi_out, "w", newline="\n") as f:
        f.write("\n".join(pi_lines) + ("\n" if pi_lines else ""))
PYEOF

# --- Run analysis ---
python3 << 'PYEOF'
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
# Pin LF on stdout (Windows pipe \r\n translation breaks bash consumers).
sys.stdout.reconfigure(newline="\n")

WEEKS = int(os.environ.get("WEEKS", "4"))
JSON_OUTPUT = os.environ.get("JSON_OUTPUT", "false") == "true"
SKILLS_FILE = os.environ.get("SKILLS_TMPFILE", "")
HISTORY_FILE = os.environ.get("HISTORY_FILE", "")
DATA_DIR = os.environ.get("DATA_DIR", "")

# System commands to filter out (not skill invocations)
SYSTEM_COMMANDS = {
    "/status", "/resume", "/exit", "/mcp", "/plugin", "/usage", "/clear",
    "/effort", "/rename", "/login", "/skills", "/compact", "/model",
    "/config", "/permissions", "/reload-plugins", "/add-dir", "/ide",
    "/vim", "/output-style", "/rate-limit-options", "/help", "/doctor",
    "/memory", "/init", "/cost", "/review", "/terminal-setup", "/fast",
    "/hooks", "/listen", "/bug", "/diff", "/pr-comments", "/context",
    "/logout", "/approved-tools", "/plan", "/todos"
}

# --- Load skills, deduping by realpath ---
# One physical SKILL.md reachable from two roots (Claude + Codex symlink
# installs) previously produced two identical rows whose counts read from the
# same counter — pure display noise. Keep one record; merge scope labels.
skills = []
_by_realpath = {}
if SKILLS_FILE and os.path.isfile(SKILLS_FILE):
    with open(SKILLS_FILE) as f:
        for line in f:
            # rstrip("\n") ONLY — .strip() ate the trailing tab of rows whose
            # description is empty, collapsing them into the legacy 3-column
            # shape with desc = the filesystem path (and no realpath dedup).
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t", 3)
            if len(parts) == 3:  # tolerate old 3-column rows
                scope, name, desc = parts
                realpath = ""
            elif len(parts) == 4:
                scope, name, realpath, desc = parts
            else:
                continue
            key = realpath or f"{scope}/{name}"
            if key in _by_realpath:
                existing = _by_realpath[key]
                if scope not in existing["scopes"]:
                    existing["scopes"].append(scope)
                continue
            rec = {"scope": scope, "scopes": [scope], "name": name, "desc": desc}
            _by_realpath[key] = rec
            skills.append(rec)
for s in skills:
    s["scope"] = ",".join(sorted(s.pop("scopes")))

# --- Stable identity -----------------------------------------------------------
# Usage keys must not collide across harnesses: a skill named "foo" installed
# in both ~/.claude/skills and ~/.config/opencode/skills used to share one
# usage counter, so invoking one inflated the other and swipe could rank the
# wrong copy as waste. Bare folder names stay the identity when unique; a name
# present in more than one harness gets "<first-scope>:<name>" (matching the
# invocation form users actually type, e.g. "/skill:pi-lens" for a pi-package
# skill). Plugin/package qualified names ("ns:name") were already unique and
# keep their form for backward compatibility with existing history matching.
_identity_counts = defaultdict(int)
for s in skills:
    _identity_counts[s["name"]] += 1
for s in skills:
    if _identity_counts[s["name"]] > 1 and ":" not in s["name"]:
        _first_scope = s["scope"].split(",")[0]
        s["id"] = f"{_first_scope}:{s['name']}"
    else:
        s["id"] = s["name"]

def _id_index():
    idx = {}
    for _s in skills:
        idx.setdefault(_s["name"], _s)
        idx.setdefault(_s["id"], _s)
    return idx

_ID_IDX = _id_index()

def _harness_match(s, harness):
    scopes = (s.get("scope") or "").split(",")
    if harness == "opencode":
        return any(sc.startswith("opencode") for sc in scopes)
    if harness == "pi":
        return any(sc.startswith("pi") for sc in scopes)
    if harness == "claude":
        return any(not sc.startswith(("opencode", "pi")) for sc in scopes)
    return False

def resolve_skill(inv, harness=None):
    """Map an invocation/transcript name to a skill record.
    Collects every matching skill (exact name, stable id, or bare segment
    after the last colon — Pi package names are themselves colon-qualified
    and Claude accepts bare plugin-skill invocations), then prefers a
    candidate registered under the calling harness. An OpenCode session load
    must credit the OpenCode copy, not an identical folder name in Claude's
    directory."""
    if not inv:
        return None
    candidates = []
    for _s in skills:
        if inv == _s["name"] or inv == _s["id"]:
            if _s not in candidates:
                candidates.append(_s)
    if ":" not in inv:
        for _s in skills:
            if _s in candidates:
                continue
            if inv == _s["name"].rsplit(":", 1)[-1] or inv == _s["id"].rsplit(":", 1)[-1]:
                candidates.append(_s)
    else:
        tail = inv.rsplit(":", 1)[-1]
        for _s in skills:
            if _s not in candidates and tail == _s["name"].rsplit(":", 1)[-1]:
                candidates.append(_s)
    if not candidates:
        return None
    if harness:
        for _s in candidates:
            if _harness_match(_s, harness):
                return _s
    return candidates[0]

# --- Extract keywords (reuse logic from detect_dupes.sh) ---
STOP_WORDS = {
    "use", "when", "the", "user", "wants", "to", "or", "and", "a", "an",
    "this", "skill", "also", "that", "for", "with", "in", "on", "of",
    "is", "are", "it", "be", "as", "at", "by", "from", "their", "they",
    "has", "have", "do", "does", "can", "will", "about", "not", "but",
    "if", "its", "into", "your", "you", "how", "what", "which", "any",
    "all", "each", "every", "both", "more", "most", "other", "some",
    "such", "than", "too", "very", "just", "only", "own", "same",
    "mentions", "says", "asks", "help", "create", "make", "build",
    "improve", "optimize", "review", "write", "generate", "set", "up",
    "see", "page", "content", "product", "want", "like", "need",
    "would", "should", "could", "get", "using", "used", "new", "way"
}

def extract_keywords(desc):
    words = re.findall(r'[a-z]+', desc.lower())
    return set(w for w in words if w not in STOP_WORDS and len(w) > 2)

# Build skill keyword map
skill_keywords = {}
for s in skills:
    skill_keywords[s["id"]] = extract_keywords(s["desc"])

# --- Parse history ---
now = datetime.now(timezone.utc)
cutoff = now - timedelta(weeks=WEEKS)

# Tracking structures
explicit_counts = defaultdict(lambda: defaultdict(int))  # skill -> week -> count
estimated_counts = defaultdict(lambda: defaultdict(int))
last_used = {}  # skill -> timestamp
weekly_totals = defaultdict(int)

# Missing history is a soft condition (warned by the bash wrapper): skills
# are still inventoried, all counts stay 0. The old unguarded open() made
# the whole script die with a traceback on standard installs.
history_lines = []
if HISTORY_FILE and os.path.isfile(HISTORY_FILE):
    with open(HISTORY_FILE) as f:
        history_lines = f.readlines()

for line in history_lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        display = entry.get("display", "").strip()
        ts = entry.get("timestamp", 0)
        if not display or not ts:
            continue

        entry_time = datetime.fromtimestamp(ts / 1000, tz=timezone.utc)
        if entry_time < cutoff:
            continue

        week_key = entry_time.strftime("%Y-W%W")

        # --- Explicit command detection (Claude / and Codex $.) ---
        is_slash = display.startswith("/")
        is_dollar = display.startswith("$.")
        if is_slash or is_dollar:
            cmd = display.split()[0].rstrip()
            if is_slash and cmd in SYSTEM_COMMANDS:
                continue

            # Match against known skills. Plugin skills are registered under
            # their qualified name (<plugin>:<skill>) but Claude Code accepts
            # the bare form too (`/janitor-audit` for
            # `skills-greenskeeper:janitor-audit`) — the shared resolver
            # handles exact, qualified and bare-segment forms.
            cmd_name = cmd.lstrip("/").lstrip("$.")
            matched = resolve_skill(cmd_name)
            if matched is not None:
                name = matched["id"]
                explicit_counts[name][week_key] += 1
                last_used[name] = max(
                    last_used.get(name, entry_time), entry_time
                )
                weekly_totals[week_key] += 1
        else:
            # --- Natural language detection ---
            input_words = set(re.findall(r'[a-z]+', display.lower()))
            input_keywords = input_words - STOP_WORDS

            if len(input_keywords) < 3:
                continue

            for s in skills:
                kw = skill_keywords.get(s["id"], set())
                if not kw:
                    continue

                common = input_keywords & kw
                union = input_keywords | kw
                similarity = len(common) / len(union) if union else 0

                # Higher threshold (50%) to avoid false positives
                if similarity > 0.5 and len(common) >= 3:
                    estimated_counts[s["id"]][week_key] += 1
                    if s["id"] not in last_used or entry_time > last_used[s["id"]]:
                        last_used[s["id"]] = entry_time
                    weekly_totals[week_key] += 1

# --- Transcript Skill invocations (real tool_use records) ---
# Highest-fidelity source: includes auto-triggered skills. Counted into
# explicit_counts under the matching registry name (qualified or bare).
SKILL_CALLS = os.environ.get("SKILL_CALLS_TMP", "")
_sk_rx = re.compile(r'"name":"Skill".{0,400}?"skill":"([^"]+)"', re.S)
_ts_rx = re.compile(r'"timestamp":"([0-9T:.\-]+)')
if SKILL_CALLS and os.path.isfile(SKILL_CALLS):
    with open(SKILL_CALLS, errors="replace") as f:
        for line in f:
            for m in _sk_rx.finditer(line):
                inv = m.group(1)
                ts_m = _ts_rx.search(line)
                try:
                    t = datetime.fromisoformat(ts_m.group(1)[:19]).replace(tzinfo=timezone.utc) if ts_m else None
                except Exception:
                    t = None
                if t is None or t < cutoff:
                    continue
                wk = t.strftime("%Y-W%W")
                matched = resolve_skill(inv)
                if matched is not None:
                    name = matched["id"]
                    explicit_counts[name][wk] += 1
                    if name not in last_used or t > last_used[name]:
                        last_used[name] = t
                    weekly_totals[wk] += 1

# --- OpenCode + Pi invocations (name<TAB>date files from the bash wrapper) ---
# Highest-fidelity sources like the Claude transcript records above: every
# entry is a real skill load, so they count into explicit_counts under the
# matching registry name (qualified or bare folder name).
for _harness_env, _harness_name in (("OPENCODE_CALLS_TMP", "opencode"),
                                     ("PI_CALLS_TMP", "pi")):
    _hf = os.environ.get(_harness_env, "")
    if not _hf or not os.path.isfile(_hf):
        continue
    with open(_hf, encoding="utf-8", errors="replace") as _f:
        for _line in _f:
            _parts = _line.strip().split("\t")
            if len(_parts) != 2:
                continue
            _inv, _day = _parts
            if not _inv:
                continue
            try:
                _t = datetime.strptime(_day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            except Exception:
                continue
            if _t < cutoff:
                continue
            _wk = _t.strftime("%Y-W%W")
            _matched = resolve_skill(_inv, harness=_harness_name)
            if _matched is not None:
                _name = _matched["id"]
                explicit_counts[_name][_wk] += 1
                last_used[_name] = max(
                    last_used.get(_name, _t), _t
                )
                weekly_totals[_wk] += 1

# --- Build results ---
# Saved and joined by stable identity; the display name stays the readably
# qualified folder name for reports and the swipe deck.
results = []
for s in skills:
    sid = s["id"]
    exp_total = sum(explicit_counts[sid].values())
    est_total = sum(estimated_counts[sid].values())
    total = exp_total + est_total
    lu = last_used.get(sid)
    lu_str = lu.strftime("%Y-%m-%d") if lu else "never"
    weeks_since = int((now - lu).days / 7) if lu else -1

    results.append({
        "id": sid,
        "name": s["name"],
        "scope": s["scope"],
        "explicit": exp_total,
        "estimated": est_total,
        "total": total,
        "last_used": lu_str,
        "weeks_since_use": weeks_since,
        "explicit_weekly": dict(explicit_counts[sid]),
        "estimated_weekly": dict(estimated_counts[sid]),
    })

# Sort: most used first, then alphabetical
results.sort(key=lambda x: (-x["total"], x["name"]))

active_skills = [r for r in results if r["total"] > 0]
unused_skills = [r for r in results if r["total"] == 0]

# --- Save persistent data ---
if DATA_DIR:
    usage_file = os.path.join(DATA_DIR, "usage-history.json")
    existing = {}
    if os.path.isfile(usage_file):
        try:
            with open(usage_file) as f:
                existing = json.load(f)
        except (json.JSONDecodeError, IOError):
            existing = {}

    # Merge: keep last 12 weeks
    all_weeks = set(existing.get("weekly_totals", {}).keys())
    all_weeks.update(weekly_totals.keys())
    sorted_weeks = sorted(all_weeks)[-12:]

    merged_weekly = {}
    for w in sorted_weeks:
        merged_weekly[w] = weekly_totals.get(w, existing.get("weekly_totals", {}).get(w, 0))

    save_data = {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "period_weeks": WEEKS,
        "total_skills": len(results),
        "active_skills": len(active_skills),
        "unused_skills": len(unused_skills),
        "weekly_totals": merged_weekly,
        # Keyed by stable id ("name" when unique across harnesses, else
        # "<scope>:<name>"); legacy name-keyed entries stay readable via the
        # name fallback in consumers.
        "skills": {r["id"]: {
            "name": r["name"],
            "explicit": r["explicit"],
            "estimated": r["estimated"],
            "total": r["total"],
            "last_used": r["last_used"],
        } for r in results}
    }

    with open(usage_file, "w") as f:
        json.dump(save_data, f, indent=2)

# --- Output ---
if JSON_OUTPUT:
    output = {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "period_weeks": WEEKS,
        "cutoff_date": cutoff.strftime("%Y-%m-%d"),
        "total_skills": len(results),
        "active_count": len(active_skills),
        "unused_count": len(unused_skills),
        "skills": results,
        "weekly_totals": dict(sorted(weekly_totals.items())),
    }
    print(json.dumps(output, indent=2, default=str))
else:
    period_start = cutoff.strftime("%Y-%m-%d")
    period_end = now.strftime("%Y-%m-%d")

    print(f"=== Skills Greenskeeper - Usage Report ===")
    print(f"Period: {period_start} to {period_end} ({WEEKS} weeks)")
    print(f"Total skills tracked: {len(results)}")
    print()

    if active_skills:
        print("--- Most Used ---")
        print(f"  {'Skill':<35} {'Explicit':>8} {'Estimated':>9} {'Total':>5}  {'Last Used':<10}")
        for r in active_skills:
            print(f"  {r['name']:<35} {r['explicit']:>8} {r['estimated']:>9} {r['total']:>5}  {r['last_used']:<10}")
        print()

    if unused_skills:
        print(f"--- Never Used ({len(unused_skills)} skills) ---")
        for r in unused_skills[:15]:
            print(f"  {r['name']:<35} ({r['scope']})")
        if len(unused_skills) > 15:
            print(f"  ... and {len(unused_skills) - 15} more")
        print()

    if weekly_totals:
        print("--- Weekly Trend ---")
        print(f"  {'Week':<12} {'Invocations':>12}")
        for week in sorted(weekly_totals.keys()):
            print(f"  {week:<12} {weekly_totals[week]:>12}")
        print()

    pct_active = (len(active_skills) / len(results) * 100) if results else 0
    pct_unused = (len(unused_skills) / len(results) * 100) if results else 0
    print("=== Summary ===")
    print(f"  Active skills: {len(active_skills)} / {len(results)} ({pct_active:.0f}%)")
    print(f"  Unused skills: {len(unused_skills)} ({pct_unused:.0f}%)")
    if active_skills:
        top = active_skills[0]
        print(f"  Most used: {top['name']} ({top['total']} total)")
    if pct_unused > 50:
        print(f"  Recommendation: Consider removing {len(unused_skills)} unused skills to reduce context overhead")

PYEOF
