#!/bin/bash
# Seam 2: multi-harness regression tests under a fixture $HOME.
#
# Pins the greenskeeper work: skills from Claude Code, Codex (~/.agents),
# OpenCode and Pi (incl. npm-package skills) share one inventory; usage comes
# from the OpenCode SQLite store and Pi session JSONL; MCP servers carry
# kind/cfg/pointer provenance; swipe --apply removes JSONC keys surgically
# and JSON keys by pointer, always with a .bak backup.
#
# Tests observe external behavior only: scan JSON, usage reports, mcp JSON,
# and file bytes after swipe --apply. No framework; must stay green on macOS
# bash 3.2 (no associative arrays, no mapfile).
#
# Two known Windows-environment limits (also true on main): symlinks and
# CRLF byte-identity are NOT asserted here — ln -s copies without privilege
# and the MSYS runtime translates line endings.

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d -t greenskeeper-seam2.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- Fixture home -----------------------------------------------------------
FIXTURE_HOME="$TMP/home"
mkdir -p "$FIXTURE_HOME/.claude/skills/cc" \
         "$FIXTURE_HOME/.agents/skills/uni" \
         "$FIXTURE_HOME/.config/opencode/skills/oc" \
         "$FIXTURE_HOME/.config/opencode/agents" \
         "$FIXTURE_HOME/.pi/agent/skills/pi" \
         "$FIXTURE_HOME/.pi/agent/prompts" \
         "$FIXTURE_HOME/.pi/agent/extensions" \
         "$FIXTURE_HOME/.pi/agent/npm/node_modules/fake-pkg/skills/pk" \
         "$FIXTURE_HOME/.local/share/opencode" \
         "$FIXTURE_HOME/.pi/agent/sessions/--test--"

mkskill() {
    printf -- '---\nname: %s\ndescription: Does example things. Use when the user asks for an example.\n---\n# Title\n\nBody text here.\n\n## Steps\n\n1. Do it.\n\n## Gotchas\n\n- Example.\n' "$1" > "$2"
}
mkskill cc "$FIXTURE_HOME/.claude/skills/cc/SKILL.md"
mkskill uni "$FIXTURE_HOME/.agents/skills/uni/SKILL.md"
mkskill oc "$FIXTURE_HOME/.config/opencode/skills/oc/SKILL.md"
mkskill pi "$FIXTURE_HOME/.pi/agent/skills/pi/SKILL.md"
mkskill pk "$FIXTURE_HOME/.pi/agent/npm/node_modules/fake-pkg/skills/pk/SKILL.md"
cp "$FIXTURE_HOME/.pi/agent/npm/node_modules/fake-pkg/skills/pk/SKILL.md" "$TMP/pk-orig.md"

printf -- '{\n  "name": "fake-pkg",\n  "pi": { "skills": ["./skills"] }\n}\n' \
    > "$FIXTURE_HOME/.pi/agent/npm/node_modules/fake-pkg/package.json"
printf -- '{\n  "packages": ["npm:fake-pkg"]\n}\n' \
    > "$FIXTURE_HOME/.pi/agent/settings.json"

printf -- '---\ndescription: Reviews code. Use when review is asked.\nmode: subagent\n---\nYou review.\n' \
    > "$FIXTURE_HOME/.config/opencode/agents/reviewer.md"
printf -- '---\ndescription: Review staged changes\n---\nReview them.\n' \
    > "$FIXTURE_HOME/.pi/agent/prompts/review.md"
printf -- 'export default function (pi) {}\n' \
    > "$FIXTURE_HOME/.pi/agent/extensions/hello.ts"

# Neutral cwd so project scopes stay empty.
WORKDIR="$TMP/work"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

export HOME="$FIXTURE_HOME"

# --- Scan: every harness present with qualified scopes ----------------------
echo "scan: all harnesses inventoried"
SCAN_JSON="$TMP/scan.json"
if bash "$REPO_DIR/scripts/scan.sh" > "$SCAN_JSON" 2>"$TMP/scan.err"; then
    pass "scan.sh exited 0"
else
    fail "scan.sh exited nonzero"
    sed 's/^/    | /' "$TMP/scan.err"
fi
SCAN_CHECK=$(python3 - "$SCAN_JSON" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
want = {"cc": "user", "uni": "codex-user", "oc": "opencode-user",
        "pi": "pi-user", "pk": "pi-package"}
got = {s["folder"]: (s["scope"], s.get("namespace") or "") for s in data["skills"]}
for folder, scope in sorted(want.items()):
    if folder not in got:
        print("MISSING %s" % folder)
    elif got[folder][0] != scope:
        print("WRONG %s: %r" % (folder, got[folder]))
    else:
        print("OK %s" % folder)
ns = got.get("pk", ("", ""))[1]
print("NS %s" % ("OK" if ns == "npm:fake-pkg" else "WRONG %r" % ns))
inv = {a["name"]: (a["scope"], a.get("kind")) for a in data.get("agents", [])}
print("AGENT %s" % ("OK" if inv.get("reviewer") == ("user", "opencode") else "WRONG %r" % inv))
print("PROMPT %s" % ("OK" if any(p["name"] == "review" for p in data.get("prompts", [])) else "MISSING"))
print("EXT %s" % ("OK" if any(e["name"] == "hello" for e in data.get("extensions", [])) else "MISSING"))
PYEOF
)
for want in "OK cc" "OK uni" "OK oc" "OK pi" "OK pk" "NS OK" "AGENT OK" "PROMPT OK" "EXT OK"; do
    if printf '%s\n' "$SCAN_CHECK" | grep -qx "$want"; then
        pass "scan $want"
    else
        fail "scan check '$want'"
        printf '%s\n' "$SCAN_CHECK" | sed 's/^/    | /'
    fi
done

# --- Lint: healthy fixtures, all harness sections ---------------------------
echo "lint: zero findings, all harnesses listed"
LINT_OUT=$(bash "$REPO_DIR/scripts/lint.sh" 2>&1)
if printf '%s\n' "$LINT_OUT" | grep -q "Critical: 0"; then
    pass "lint zero critical"
else
    fail "lint findings nonzero"
    printf '%s\n' "$LINT_OUT" | sed 's/^/    | /'
fi
for section in "User Skills" "Codex User Skills" "OpenCode User Skills" "Pi User Skills"; do
    if printf '%s\n' "$LINT_OUT" | grep -q -- "--- $section"; then
        pass "lint section '$section'"
    else
        fail "lint missing section '$section'"
    fi
done

# --- Fix --apply: package skill untouched, user skill fixed ------------------
echo "fix --apply: package-managed skill is never written"
FIX_OUT=$(bash "$REPO_DIR/scripts/fix.sh" --apply 2>&1)
FIX_STATUS=$?
[ "$FIX_STATUS" -eq 0 ] && pass "fix.sh --apply exited 0" || fail "fix.sh exited $FIX_STATUS"
if cmp -s "$TMP/pk-orig.md" "$FIXTURE_HOME/.pi/agent/npm/node_modules/fake-pkg/skills/pk/SKILL.md"; then
    pass "package skill byte-identical"
else
    fail "package skill was modified"
fi
if grep -q '^metadata:$' "$FIXTURE_HOME/.config/opencode/skills/oc/SKILL.md"; then
    pass "opencode user skill received metadata.version"
else
    fail "opencode user skill was not fixed"
fi

# --- Usage: OpenCode SQLite + Pi sessions ------------------------------------
echo "usage: cross-harness invocation counts"
cat > "$FIXTURE_HOME/.pi/agent/sessions/--test--/2026-09-28T00-00-00-000Z_t.jsonl" <<'EOF'
{"type":"session","version":3,"id":"t","timestamp":"2026-09-28T00:00:00.000Z","cwd":"/tmp"}
{"type":"message","id":"a1","parentId":null,"timestamp":"2026-09-28T01:00:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/tmp/x/.pi/agent/skills/pi/SKILL.md"}}]}}
{"type":"message","id":"a2","parentId":"a1","timestamp":"2026-09-28T02:00:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"read","arguments":{"path":"/tmp/x/npm/node_modules/fake-pkg/skills/pk/SKILL.md"}}]}}
EOF
python3 - "$FIXTURE_HOME/.local/share/opencode/opencode.db" <<'PYEOF'
import json, sqlite3, sys
from datetime import datetime, timezone
db = sys.argv[1]
ms = int(datetime(2026, 9, 28, 2, 0, tzinfo=timezone.utc).timestamp() * 1000)
con = sqlite3.connect(db)
con.execute("CREATE TABLE session (id TEXT PRIMARY KEY, time_updated INTEGER NOT NULL)")
con.execute("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL)")
con.execute("INSERT INTO session VALUES (?, ?)", ("s1", ms))
part = {"type": "tool", "tool": "skill", "state": {"status": "x", "input": {"name": "oc"}}}
con.execute("INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)",
            ("p1", "m1", "s1", ms, ms, json.dumps(part)))
con.commit()
con.close()
PYEOF
USAGE_JSON="$TMP/usage.json"
bash "$REPO_DIR/scripts/usage.sh" --weeks 52 --json > "$USAGE_JSON" 2>"$TMP/usage.err" || fail "usage.sh exited nonzero"
USAGE_CHECK=$(python3 - "$USAGE_JSON" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
got = {r["name"]: r["total"] for r in data["skills"]}
print("OC %s" % ("OK" if got.get("oc", 0) >= 1 else "WRONG %r" % got))
print("PI %s" % ("OK" if got.get("pi", 0) >= 1 else "WRONG %r" % got))
print("PK %s" % ("OK" if got.get("npm:fake-pkg:pk", 0) >= 1 else "WRONG %r" % got))
PYEOF
)
for want in "OC OK" "PI OK" "PK OK"; do
    if printf '%s\n' "$USAGE_CHECK" | grep -qx "$want"; then
        pass "usage $want"
    else
        fail "usage check '$want'"
        printf '%s\n' "$USAGE_CHECK" | sed 's/^/    | /'
    fi
done

# --- MCP: inventory kinds, usage, disabled exclusion ------------------------
echo "mcp: kinds, usage and disabled servers"
cat > "$FIXTURE_HOME/.config/opencode/opencode.jsonc" <<'EOF'
// Fixture config with comments.
{
  // servers:
  "mcp": {
    "ocm": {
      "type": "local",
      "command": ["npx", "-y", "x"],
    },
  },
}
EOF
mkdir -p "$FIXTURE_HOME/.pi/agent"
cat > "$FIXTURE_HOME/.pi/agent/mcp.json" <<'EOF'
{
  "mcpServers": {
    "pim": {
      "command": "npx",
      "args": ["-y", "y"]
    },
    "pioff": {
      "command": "z",
      "enabled": false
    }
  }
}
EOF
# Project config with non-standard {"mcp": {"servers": {...}}} nesting.
cat > "$WORKDIR/opencode.json" <<'EOF'
{
  "mcp": {
    "servers": {
      "ocnest": {
        "type": "local",
        "command": ["npx", "nested"]
      }
    }
  }
}
EOF
MCP_JSON="$TMP/mcp.json"
bash "$REPO_DIR/scripts/mcp.sh" --weeks 52 --json > "$MCP_JSON" 2>"$TMP/mcp.err" || fail "mcp.sh exited nonzero"
MCP_CHECK=$(python3 - "$MCP_JSON" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
got = {s["name"]: s for s in data["servers"]}
ok = True
for name, scope, kind in [("ocm", "mcp-opencode-user", "opencode"),
                          ("pim", "mcp-pi-user", "pi"),
                          ("ocnest", "mcp-opencode-project", "opencode")]:
    s = got.get(name)
    if not s or s["scope"].split(",")[0] != scope or s["kind"] != kind:
        print("WRONG %s: %r" % (name, s))
        ok = False
    if not s or not s.get("cfg") or not s.get("pointer"):
        print("NOPROV %s" % name)
        ok = False
if got.get("ocnest", {}).get("pointer") != ["mcp", "servers", "ocnest"]:
    print("WRONGPTR %r" % got.get("ocnest"))
    ok = False
if "servers" in got:
    print("PSEUDO servers inventoried")
    ok = False
if ok:
    print("INV OK")
off = got.get("pioff", {})
print("OFF %s" % ("OK" if off.get("last_used") == "disabled" else "WRONG %r" % off))
unused_names = [s["name"] for s in data["servers"] if s["calls"] == 0 and s.get("enabled", True)]
print("UNUSED2 %s" % ("OK" if "pioff" not in unused_names else "WRONG"))
PYEOF
)
for want in "INV OK" "OFF OK" "UNUSED2 OK"; do
    if printf '%s\n' "$MCP_CHECK" | grep -qx "$want"; then
        pass "mcp $want"
    else
        fail "mcp check '$want'"
        printf '%s\n' "$MCP_CHECK" | sed 's/^/    | /'
    fi
done

# --- jsonc.py: comment-safe parsing and span removal -------------------------
echo "jsonc: parse and surgical removal"
JSONC_CHECK=$(python3 - "$REPO_DIR/scripts" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from jsonc import parse_jsonc, jsonc_remove_key
ok = []
doc = '{\n// c\n"mcp": {\n"a": {"x": 1}, // keep\n"b": {"y": 2},\n"c": {"z": 3},\n},\n}\n'
d = parse_jsonc(doc)
ok.append("PARSE" if sorted(d["mcp"]) == ["a", "b", "c"] else "parse")
out = jsonc_remove_key(doc, ["mcp", "b"])
d2 = parse_jsonc(out)
ok.append("MID" if sorted(d2["mcp"]) == ["a", "c"] and "// c" in out and "// keep" in out else "mid:%r" % out)
out = jsonc_remove_key(doc, ["mcp", "a"])
ok.append("FIRST" if sorted(parse_jsonc(out)["mcp"]) == ["b", "c"] else "first")
out = jsonc_remove_key(doc, ["mcp", "c"])
ok.append("LAST" if sorted(parse_jsonc(out)["mcp"]) == ["a", "b"] else "last")
try:
    jsonc_remove_key(doc, ["mcp", "nope"])
    ok.append("missing-no-raise")
except ValueError:
    ok.append("MISSING")
for o in ok:
    print(o)
PYEOF
)
for want in PARSE MID FIRST LAST MISSING; do
    if printf '%s\n' "$JSONC_CHECK" | grep -qx "$want"; then
        pass "jsonc $want"
    else
        fail "jsonc check '$want'"
        printf '%s\n' "$JSONC_CHECK" | sed 's/^/    | /'
    fi
done

# --- Swipe deck: all harness scopes become cards -------------------------------
echo "swipe deck: cross-harness cards"
bash "$REPO_DIR/scripts/swipe-build-deck.sh" "$TMP/deck.json" > /dev/null 2>"$TMP/deck.err" || fail "swipe-build-deck.sh exited nonzero"
DECK_CHECK=$(python3 - "$TMP/deck.json" <<'PYEOF'
import json, sys
deck = json.load(open(sys.argv[1]))
scopes = sorted({c["scope"] for c in deck["cards"]})
print(" ".join(scopes))
PYEOF
)
for scope in user codex-user opencode-user pi-user pi-package; do
    if printf '%s\n' "$DECK_CHECK" | grep -qw "$scope"; then
        pass "deck card '$scope'"
    else
        fail "deck missing scope '$scope' (got: $DECK_CHECK)"
    fi
done

# --- Swipe --apply: jsonc span removal, json pointer delete, skill rm -------
echo "swipe --apply: config edits with backups"
DECK="$TMP/deck.json"
python3 - "$DECK" "$FIXTURE_HOME" <<'PYEOF'
import json, sys
home = sys.argv[2].replace("\\", "/")
def card(cid, name, scope, path, kind="", cfg="", pointer=None, tokens=100):
    return {"id": cid, "name": name, "scope": scope, "namespace": None,
            "path": path, "tokens": tokens, "desc_tokens": 20,
            "body_tokens": 80, "tokens_pct_budget": 0.1, "invocations": 0,
            "last_used": "never", "days_since_use": None, "description": "d",
            "kind": kind, "cfg": cfg, "pointer": pointer,
            "verdict": {"score": 90.0, "label": "x", "tone": "warn"},
            "decision": "delete"}
deck = {"built_at": "t", "budget": 200000, "total_cards": 3, "cards": [
    card("m::ocm", "ocm", "mcp-opencode-user",
         home + "/.config/opencode/opencode.jsonc",
         "opencode", home + "/.config/opencode/opencode.jsonc",
         ["mcp", "ocm"], 0),
    card("m::pim", "pim", "mcp-pi-user", home + "/.pi/agent/mcp.json",
         "pi", home + "/.pi/agent/mcp.json", ["mcpServers", "pim"], 0),
    card("u::oc", "oc", "opencode-user",
         home + "/.config/opencode/skills/oc"),
]}
json.dump(deck, open(sys.argv[1], "w"), indent=2)
PYEOF
printf 'y\n' | bash "$REPO_DIR/scripts/swipe.sh" --apply "$DECK" > "$TMP/apply.out" 2>&1
if grep -q "removed.*MCP ocm" "$TMP/apply.out" && grep -q "removed.*MCP pim" "$TMP/apply.out" \
    && grep -q "  oc$" "$TMP/apply.out"; then
    pass "apply removed all three targets"
else
    fail "apply output missing removals"
    sed 's/^/    | /' "$TMP/apply.out"
fi
if [ ! -d "$FIXTURE_HOME/.config/opencode/skills/oc" ]; then
    pass "skill dir removed"
else
    fail "skill dir still present"
fi
if python3 - "$REPO_DIR/scripts" "$FIXTURE_HOME/.config/opencode/opencode.jsonc" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from jsonc import parse_jsonc
d = parse_jsonc(open(sys.argv[2]).read())
sys.exit(0 if "ocm" not in d.get("mcp", {}) else 1)
PYEOF
then
    pass "jsonc key gone, file still parses"
else
    fail "jsonc key still present or file invalid"
fi
if grep -q "// Fixture config" "$FIXTURE_HOME/.config/opencode/opencode.jsonc"; then
    pass "jsonc comment survived"
else
    fail "jsonc comment was destroyed"
fi
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'pim' not in d.get('mcpServers', {}) else 1)" \
    "$FIXTURE_HOME/.pi/agent/mcp.json" 2>/dev/null; then
    pass "pi json key gone"
else
    fail "pi json key still present"
fi
if ls "$FIXTURE_HOME/.config/opencode/opencode.jsonc.bak-janitor-"* >/dev/null 2>&1 \
    && ls "$FIXTURE_HOME/.pi/agent/mcp.json.bak-janitor-"* >/dev/null 2>&1; then
    pass "both configs have .bak backups"
else
    fail "missing .bak backup"
fi

# --- Launcher: every documented command dispatches ---------------------------
echo "greenskeeper: help and dispatch"
if bash "$REPO_DIR/greenskeeper" --help 2>&1 | grep -q "mcp \[--weeks N\]"; then
    pass "launcher help lists all commands"
else
    fail "launcher help incomplete"
fi
for s in scan lint detect_dupes fix value security discover mcp usage swipe; do
    if bash "$REPO_DIR/scripts/$s.sh" --help >/dev/null 2>&1; then
        pass "help $s"
    else
        fail "help $s exits nonzero"
    fi
done
if bash "$REPO_DIR/greenskeeper" report --brief > "$TMP/jrep.json" 2>/dev/null \
    && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/jrep.json"; then
    pass "launcher report --brief emits valid JSON"
else
    fail "launcher report --brief failed"
fi

# --- Dashboard: snapshot build + append --------------------------------------
echo "dashboard: snapshot history"
export GREENSKEEPER_DATA_DIR="$TMP/dashdata"
if bash "$REPO_DIR/scripts/dashboard.sh" --no-open > "$TMP/dash1.out" 2>&1 \
    && bash "$REPO_DIR/scripts/dashboard.sh" --no-open > "$TMP/dash2.out" 2>&1; then
    pass "dashboard.sh ran twice with --no-open"
else
    fail "dashboard.sh exited nonzero"
    sed 's/^/    | /' "$TMP/dash1.out" "$TMP/dash2.out"
fi
DASH_CHECK=$(python3 - "$TMP/dashdata/greenskeeper-dashboard.html" <<'PYEOF'
import json, re, sys
html = open(sys.argv[1]).read()
m = re.search(r'<script type="application/json" id="snapshotData">(.*?)</script>',
              html, re.S)
if not m:
    print("NOMARKER")
    sys.exit(0)
snaps = json.loads(m.group(1))
print("COUNT %d" % len(snaps))
names = set()
for s in snaps:
    for sk in (s.get("scan") or {}).get("skills", []):
        names.add(sk.get("folder"))
print("SKILLS %s" % ("OK" if {"cc", "uni", "pi", "pk"} <= names else "WRONG %r" % sorted(names)))
print("TITLE %s" % ("OK" if "Skills Greenskeeper Dashboard" in html else "WRONG"))
PYEOF
)
for want in "COUNT 2" "SKILLS OK" "TITLE OK"; do
    if printf '%s\n' "$DASH_CHECK" | grep -qx "$want"; then
        pass "dashboard $want"
    else
        fail "dashboard check '$want'"
        printf '%s\n' "$DASH_CHECK" | sed 's/^/    | /'
    fi
done

# --- Summary ----------------------------------------------------------------
echo
echo "seam 2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
