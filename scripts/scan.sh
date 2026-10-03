#!/bin/bash
# Skills Greenskeeper - Scan & Inventory
# Discovers all skills across all scopes and outputs a JSON inventory.
#
# Performance note: bash collects one TSV row per skill/agent/command and a
# SINGLE python3 process renders the whole JSON document. The previous
# implementation spawned ~6 python3 processes per skill for JSON escaping,
# which took ~55s on a 175-skill machine; this takes ~8s. It also means every
# field (including paths) is properly JSON-escaped.

set -euo pipefail

command -v python3 &>/dev/null || { echo "ERROR: python3 required" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: scan.sh"
    echo ""
    echo "JSON inventory of all skills (every harness and scope), agents,"
    echo "plugins, commands, prompts and extensions. Powers every report."
    exit 0
fi

# --- Load platform paths ---
source "$(dirname "$0")/paths.sh"

# Absolute path so the python pass can import tsv_reader.py regardless of cwd
JANITOR_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Agent/command dirs are enumerated inline below (Claude + OpenCode).

# --- Row encoding ---
# Tab-separated; literal tabs/newlines inside a value are replaced with a
# space; empty values become the sentinel "_" (bash `read` with IFS=$'\t'
# collapses consecutive tabs). Python decodes "_" back to empty.
SKILLS_TSV=$(mktemp -t janitor-scan.XXXXXX)
AGENTS_TSV=$(mktemp -t janitor-scan.XXXXXX)
COMMANDS_TSV=$(mktemp -t janitor-scan.XXXXXX)
PROMPTS_TSV=$(mktemp -t janitor-scan.XXXXXX)
EXTS_TSV=$(mktemp -t janitor-scan.XXXXXX)
trap 'rm -f "$SKILLS_TSV" "$AGENTS_TSV" "$COMMANDS_TSV" "$PROMPTS_TSV" "$EXTS_TSV"' EXIT

_f() {  # sanitize one field for the TSV row
    local v="${1:-}"
    v="${v//$'\t'/ }"
    v="${v//$'\n'/ }"
    [[ -z "$v" ]] && v="_"
    printf '%s' "$v"
}

scan_skill() {
    local path="$1"
    local scope="$2"
    local namespace="${3:-}"
    local skill_name
    skill_name=$(basename "$path")

    # Skip self (plugin data dir, not a real skill)
    [[ "$skill_name" == "skills-greenskeeper" ]] && return 0

    local qualified_name="$skill_name"
    if [[ -n "$namespace" ]]; then
        qualified_name="${namespace}:${skill_name}"
    fi

    local skill_file=""
    if [[ -f "$path/SKILL.md" ]]; then
        skill_file="$path/SKILL.md"
    elif [[ -f "$path/Skill.md" ]]; then
        skill_file="$path/Skill.md"
    fi

    local is_symlink="false"
    local symlink_target=""
    if [[ -L "$path" ]]; then
        is_symlink="true"
        symlink_target=$(readlink "$path" 2>/dev/null || echo "broken")
        if [[ ! -e "$path" ]]; then
            symlink_target="BROKEN:$symlink_target"
        fi
    fi

    local name_field=""
    local description=""
    local version=""
    local has_frontmatter="false"
    local has_body="false"
    local line_count=0

    if [[ -n "$skill_file" && -f "$skill_file" ]]; then
        line_count=$(wc -l < "$skill_file" | tr -d ' ')

        if head -1 "$skill_file" | grep -q '^---'; then
            has_frontmatter="true"
            local frontmatter
            frontmatter=$(awk 'NR==1 && /^---\r?$/{next} /^---\r?$/{exit} {print}' "$skill_file")
            # tr -d '\r' is load-bearing, not cosmetic: these values are written
            # into a TSV that python reads with universal newlines, where a bare
            # CR terminates a line. A CRLF skill's "name: foo\r" split its row in
            # two, both halves failed read_tsv's field-count check, and the skill
            # vanished from the inventory with no error.
            name_field=$(echo "$frontmatter" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d '\r' || true)
            # Shared helper handles block scalars (|, >) that a plain grep misses
            description=$(extract_description "$skill_file")
            version=$(echo "$frontmatter" | grep -E '^version:' | head -1 | sed 's/^version:[[:space:]]*//' | tr -d '"' | tr -d '\r' || true)
        fi

        local body_start
        body_start=$(awk '/^---\r?$/{c++; if(c==2){print NR; exit}}' "$skill_file" 2>/dev/null || echo "0")
        if [[ "${body_start:-0}" -gt 0 ]]; then
            local remaining
            # `|| true`, not `|| echo 0` — grep -c already prints "0" when it
            # exits 1 (no matches); the old form yielded "0\n0".
            remaining=$(tail -n +"$((body_start + 1))" "$skill_file" | grep -c '[^ ]' 2>/dev/null || true)
            remaining=${remaining:-0}
            if [[ "$remaining" -gt 0 ]]; then
                has_body="true"
            fi
        fi
    fi

    local extra_files=0
    if [[ -d "$path" ]]; then
        extra_files=$(find "$path" -type f ! -name "SKILL.md" ! -name "Skill.md" ! -name ".DS_Store" 2>/dev/null | wc -l | tr -d ' ')
    fi

    local has_skill_file="false"
    [[ -n "$skill_file" ]] && has_skill_file="true"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(_f "$skill_name")" "$(_f "$scope")" "$(_f "$namespace")" \
        "$(_f "$qualified_name")" "$(_f "$path")" "$is_symlink" \
        "$(_f "$symlink_target")" "$has_skill_file" "$(_f "$name_field")" \
        "$(_f "$description")" "$(_f "$version")" "$has_frontmatter" \
        "$has_body" "$line_count" "$extra_files" >> "$SKILLS_TSV"
}

# Walk every registered skill directory (user/project/codex/opencode/pi,
# plugin/source/package).
_scan_iter() {
    local parent_dir="$1" scope="$2" _platform="$3" namespace="${4:-}"
    if [[ "$_platform" != "claude" ]]; then
        scope="${_platform}-${scope}"
    fi
    # No trailing slash on the glob: `*/` silently skips broken symlinks,
    # which must still appear in the inventory.
    for skill_dir in "$parent_dir"/*; do
        [[ -d "$skill_dir" || -L "$skill_dir" ]] || continue
        [[ -f "$skill_dir" ]] && continue
        scan_skill "$skill_dir" "$scope" "$namespace"
    done
}
for_each_skill_dir _scan_iter

# --- Subagents (Claude + OpenCode markdown agents) ---
# Agents are single markdown files with YAML frontmatter. Their descriptions
# are always loaded into context, same as skill descriptions — often costing
# MORE than skills — so the greenskeeper inventories them too.
scan_agent() {
    local file="$1" scope="$2" kind="$3"
    local agent_name description model word_count
    agent_name=$(basename "$file" .md)
    # Shared helper: handles block-scalar descriptions like the skill side
    description=$(extract_description "$file")
    model=$(awk 'NR==1 && /^---\r?$/{started=1; next} started && /^---\r?$/{exit} started && /^model:/{sub(/^model:[[:space:]]*/,""); print; exit}' "$file" || true)
    word_count=$(wc -w < "$file" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(_f "$agent_name")" "$(_f "$scope")" "$(_f "$kind")" "$(_f "$file")" \
        "$(_f "$description")" "$(_f "$model")" "$word_count" >> "$AGENTS_TSV"
}
# Dedup: running from $HOME makes user/project pairs the same physical dir.
_seen_adirs=""
_scan_agent_dir() {
    local dir="$1" scope="$2" kind="$3"
    [[ -d "$dir" ]] || return 0
    local real_dir
    real_dir=$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")
    case "|$_seen_adirs|" in *"|$real_dir|"*) return 0 ;; esac
    _seen_adirs="$_seen_adirs|$real_dir"
    for agent_file in "$dir"/*.md; do
        [[ -f "$agent_file" ]] || continue
        scan_agent "$agent_file" "$scope" "$kind"
    done
}
_scan_agent_dir "$HOME/.claude/agents" "user" "claude"
_scan_agent_dir "./.claude/agents" "project" "claude"
_scan_agent_dir "$HOME/.config/opencode/agents" "user" "opencode"
_scan_agent_dir "./.opencode/agents" "project" "opencode"

# --- Commands (Claude + OpenCode markdown commands, same dedup) ---
_scan_cmd_dir() {
    local dir="$1" scope="$2" kind="$3"
    [[ -d "$dir" ]] || return 0
    local real_dir
    real_dir=$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")
    case "|$_seen_adirs|" in *"|$real_dir|"*) return 0 ;; esac
    _seen_adirs="$_seen_adirs|$real_dir"
    for cmd_file in "$dir"/*.md; do
        [[ -f "$cmd_file" ]] || continue
        printf '%s\t%s\t%s\t%s\n' "$(_f "$(basename "$cmd_file" .md)")" "$scope" "$(_f "$kind")" "$(_f "$cmd_file")" >> "$COMMANDS_TSV"
    done
}
_scan_cmd_dir "$HOME/.claude/commands" "user" "claude"
_scan_cmd_dir "./.claude/commands" "project" "claude"
_scan_cmd_dir "$HOME/.config/opencode/commands" "user" "opencode"
_scan_cmd_dir "./.opencode/commands" "project" "opencode"

# --- Pi prompt templates (user/project prompts/*.md, direct children only) ---
# Templates become /commands; their descriptions show in completion but are
# NOT always-loaded context, so they are reported, not costed.
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
_scan_prompt_dir() {
    local dir="$1" scope="$2"
    [[ -d "$dir" ]] || return 0
    local real_dir
    real_dir=$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")
    case "|$_seen_adirs|" in *"|$real_dir|"*) return 0 ;; esac
    _seen_adirs="$_seen_adirs|$real_dir"
    for prompt_file in "$dir"/*.md; do
        [[ -f "$prompt_file" ]] || continue
        printf '%s\t%s\t%s\t%s\n' \
            "$(_f "$(basename "$prompt_file" .md)")" "$scope" \
            "$(_f "$prompt_file")" "$(_f "$(extract_description "$prompt_file")")" >> "$PROMPTS_TSV"
    done
}
_scan_prompt_dir "$PI_AGENT_DIR/prompts" "pi-user"
_scan_prompt_dir "./.pi/prompts" "pi-project"

# --- Pi extensions (user/project extensions: .ts/.js files + index dirs) ---
# Extensions are code running with user permissions — inventoried for the
# security report surface, not counted as context.
_scan_ext_dir() {
    local dir="$1" scope="$2"
    [[ -d "$dir" ]] || return 0
    local real_dir
    real_dir=$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")
    case "|$_seen_adirs|" in *"|$real_dir|"*) return 0 ;; esac
    _seen_adirs="$_seen_adirs|$real_dir"
    local entry files name
    for entry in "$dir"/*.ts "$dir"/*.js; do
        [[ -f "$entry" ]] || continue
        name=$(basename "$entry")
        name="${name%.*}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$(_f "$name")" "$scope" \
            "$(_f "$entry")" "$(_f "$entry")" "1" >> "$EXTS_TSV"
    done
    for entry in "$dir"/*/; do
        [[ -d "$entry" ]] || continue
        name=$(basename "$entry")
        local index=""
        [[ -f "${entry}index.ts" ]] && index="${entry}index.ts"
        [[ -z "$index" && -f "${entry}index.js" ]] && index="${entry}index.js"
        [[ -z "$index" ]] && continue
        files=$(find "$entry" -type f \( -name '*.ts' -o -name '*.js' \) 2>/dev/null | wc -l | tr -d ' ')
        printf '%s\t%s\t%s\t%s\t%s\n' "$(_f "$name")" "$scope" \
            "$(_f "${entry%/}")" "$(_f "$index")" "$files" >> "$EXTS_TSV"
    done
}
_scan_ext_dir "$PI_AGENT_DIR/extensions" "pi-user"
_scan_ext_dir "./.pi/extensions" "pi-project"

# --- Broken symlinks: count across ALL skill roots, not just user scope ---
broken_count=0
_broken_iter() {
    local parent_dir="$1"
    local n
    n=$(find "$parent_dir" -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l | tr -d ' ')
    broken_count=$((broken_count + n))
}
for_each_skill_dir _broken_iter

# --- Render everything in ONE python pass ---
export SKILLS_TSV AGENTS_TSV COMMANDS_TSV PROMPTS_TSV EXTS_TSV BROKEN_COUNT="$broken_count"
export INSTALLED_PLUGINS_FILE JANITOR_SCRIPT_DIR
export KNOWN_MARKETPLACES_FILE="$HOME/.claude/plugins/known_marketplaces.json"
# Importing tsv_reader must not litter the (possibly read-only) install dir
# with __pycache__
export PYTHONDONTWRITEBYTECODE=1

python3 <<'PYEOF'
import json, os, subprocess, sys
from datetime import datetime, timezone
# Pin LF on stdout (Windows pipe \r\n translation breaks bash consumers).
sys.stdout.reconfigure(newline="\n")

# The TSV reader lives in tsv_reader.py (same dir as this script) so tests can
# import it directly; it keeps the newline="\n" pin against CR record-splitting.
sys.path.insert(0, os.environ["JANITOR_SCRIPT_DIR"])
from tsv_reader import read_tsv

skills = []
for r in read_tsv(os.environ.get("SKILLS_TSV", ""), 15):
    (folder, scope, namespace, qualified, path, is_symlink, symlink_target,
     has_skill_file, name, desc, version, has_fm, has_body, line_count,
     extra_files) = r
    skills.append({
        "folder": folder,
        "scope": scope,
        "namespace": namespace or None,
        "qualified_name": qualified,
        "path": path,
        "is_symlink": is_symlink == "true",
        "symlink_target": symlink_target,
        "has_skill_file": has_skill_file == "true",
        "name": name,
        "description": desc,
        "version": version,
        "has_frontmatter": has_fm == "true",
        "has_body": has_body == "true",
        "line_count": int(line_count or 0),
        "extra_files": int(extra_files or 0),
    })

agents = []
for r in read_tsv(os.environ.get("AGENTS_TSV", ""), 7):
    name, scope, kind, path, desc, model, words = r
    agents.append({
        "name": name,
        "scope": scope,
        "kind": kind,
        "path": path,
        "description": desc,
        "model": model,
        "word_count": int(words or 0),
    })

commands = []
for r in read_tsv(os.environ.get("COMMANDS_TSV", ""), 4):
    name, scope, kind, path = r
    commands.append({"name": name, "scope": scope, "kind": kind, "path": path})

prompts = []
for r in read_tsv(os.environ.get("PROMPTS_TSV", ""), 4):
    name, scope, path, desc = r
    prompts.append({
        "name": name,
        "scope": scope,
        "kind": "pi",
        "path": path,
        "description": desc,
    })

extensions = []
for r in read_tsv(os.environ.get("EXTS_TSV", ""), 5):
    name, scope, path, entry, files = r
    extensions.append({
        "name": name,
        "scope": scope,
        "kind": "pi",
        "path": path,
        "entry": entry,
        "files": int(files or 0),
    })

# --- Plugins: installed instances + update availability ---
# update_available compares the installed commit against the HEAD of the
# marketplace clone the plugin came from (resolved via known_marketplaces).
plugins = []
marketplace_heads = {}
km_file = os.environ.get("KNOWN_MARKETPLACES_FILE", "")
if km_file and os.path.isfile(km_file):
    try:
        km = json.load(open(km_file))
        for mk_name, mk in km.items():
            loc = mk.get("installLocation", "")
            if loc and os.path.isdir(os.path.join(loc, ".git")):
                try:
                    head = subprocess.run(
                        ["git", "-C", loc, "rev-parse", "HEAD"],
                        capture_output=True, text=True, timeout=5,
                    ).stdout.strip()
                    if head:
                        marketplace_heads[mk_name] = head
                except Exception:
                    pass
    except Exception:
        pass

ip_file = os.environ.get("INSTALLED_PLUGINS_FILE", "")
if ip_file and os.path.isfile(ip_file):
    try:
        data = json.load(open(ip_file))
    except Exception:
        data = None
    if isinstance(data, dict) and isinstance(data.get("plugins"), dict):
        for key, instances in data["plugins"].items():
            if "@" in key:
                name, source = key.rsplit("@", 1)
            else:
                name, source = key, ""
            if not isinstance(instances, list):
                continue
            for inst in instances:
                if not isinstance(inst, dict):
                    continue
                sha = inst.get("gitCommitSha", "")
                head = marketplace_heads.get(source)
                update_available = None
                if sha and head:
                    update_available = not head.startswith(sha) and sha != head
                plugins.append({
                    "name": name,
                    "source": source,
                    "version": inst.get("version", ""),
                    "scope": inst.get("scope", ""),
                    "update_available": update_available,
                })
    elif isinstance(data, list):
        for p in data:
            if isinstance(p, dict):
                plugins.append({
                    "name": p.get("name", ""),
                    "version": p.get("version", ""),
                    "source": p.get("source", ""),
                    "update_available": None,
                })

out = {
    "scan_date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "skills": skills,
    "agents": agents,
    "plugins": plugins,
    "commands": commands,
    "prompts": prompts,
    "extensions": extensions,
    "broken_symlinks": int(os.environ.get("BROKEN_COUNT", "0") or 0),
}
print(json.dumps(out, indent=2))
PYEOF
