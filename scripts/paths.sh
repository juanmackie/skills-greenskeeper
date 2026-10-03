#!/bin/bash
# Skills Greenskeeper - Platform Path Detection
# Detects skill directories across Claude Code, OpenAI Codex, OpenCode and Pi
# Source this file: source "$(dirname "$0")/paths.sh"

# --- Claude Code paths ---
CLAUDE_USER_SKILLS="$HOME/.claude/skills"
CLAUDE_PROJECT_SKILLS="./.claude/skills"

# --- Claude Code plugin paths ---
# Active marketplace: ~/.claude/plugins/marketplaces/<plugin>/skills/<skill>/SKILL.md
#   (some plugins use ~/.claude/plugins/marketplaces/<plugin>/.claude/skills/ instead)
# Versioned cache:    ~/.claude/plugins/cache/<owner>/<plugin>/<version>/skills/<skill>/SKILL.md
# Sources:            ~/.claude/sources/<source>/skills/<skill>/SKILL.md
PLUGIN_MARKETPLACES="$HOME/.claude/plugins/marketplaces"
PLUGIN_CACHE="$HOME/.claude/plugins/cache"
PLUGIN_SOURCES="$HOME/.claude/sources"
INSTALLED_PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"

# --- OpenAI Codex paths ---
CODEX_USER_SKILLS="$HOME/.agents/skills"
CODEX_PROJECT_SKILLS="./.agents/skills"

# --- OpenCode paths ---
# Global config lives at ~/.config/opencode (opencode.json); skills at
# ~/.config/opencode/skills, per-project at ./.opencode/skills. OpenCode also
# reads the Claude-compatible (~/.claude/skills) and agent-compatible
# (~/.agents/skills) locations, which are covered above.
OPENCODE_USER_SKILLS="$HOME/.config/opencode/skills"
OPENCODE_PROJECT_SKILLS="./.opencode/skills"
if [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
    OPENCODE_CUSTOM_SKILLS="$OPENCODE_CONFIG_DIR/skills"
fi

# --- Pi coding agent paths ---
# Agent dir defaults to ~/.pi/agent (PI_CODING_AGENT_DIR overrides); user
# skills live directly under it, project skills under ./.pi/skills. Pi also
# reads the universal ~/.agents/skills location (covered under Codex above).
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_USER_SKILLS="$PI_AGENT_DIR/skills"
PI_PROJECT_SKILLS="./.pi/skills"
PI_GIT_ROOT="$PI_AGENT_DIR/git"
PI_NPM_ROOT="$PI_AGENT_DIR/npm/node_modules"

# --- Aggregate all valid skill directories ---
# Each entry uses `|` as a separator (filesystem paths cannot contain `|`):
#   scope|platform|namespace|path
# namespace is empty for user/project scopes; set to the plugin, source, or
# Pi package name for managed skills.
ALL_SKILL_DIRS=()

add_dir() {
    local path="$1" scope="$2" platform="$3" namespace="${4:-}"
    # An explicit `if` (not `[[ ]] &&`) so a missing directory doesn't make
    # the function return 1 — every caller sources this under `set -e`, and
    # the bare && form silently killed all scripts on machines without e.g.
    # ~/.agents/skills (any Claude-only install).
    if [[ -d "$path" ]]; then
        ALL_SKILL_DIRS+=("$scope|$platform|$namespace|$path")
    fi
}

add_dir "$CLAUDE_USER_SKILLS" "user" "claude"
add_dir "$CODEX_USER_SKILLS" "user" "codex"
add_dir "$OPENCODE_USER_SKILLS" "user" "opencode"
if [[ -n "${OPENCODE_CUSTOM_SKILLS:-}" ]]; then
    add_dir "$OPENCODE_CUSTOM_SKILLS" "user" "opencode"
fi
add_dir "$PI_USER_SKILLS" "user" "pi"

# Deduplicate project dirs (avoid scanning same real path twice when running
# from $HOME, where ./.claude/skills resolves to the same place as
# ~/.claude/skills)
_add_project_dir() {
    local path="$1" platform="$2"
    if [[ ! -d "$path" ]]; then
        return 0
    fi
    local real_path
    real_path=$(cd "$path" 2>/dev/null && pwd -P || echo "")
    local dominated=false
    # ${arr[@]+...} guard: bash 3.2 treats "${arr[@]}" on an EMPTY array as an
    # unbound variable under `set -u`. Same idiom used on every expansion below.
    for existing in ${ALL_SKILL_DIRS[@]+"${ALL_SKILL_DIRS[@]}"}; do
        local existing_path="${existing##*|}"
        local existing_real
        existing_real=$(cd "$existing_path" 2>/dev/null && pwd -P || echo "")
        if [[ "$real_path" == "$existing_real" ]]; then
            dominated=true
            break
        fi
    done
    if [[ "$dominated" == "false" ]]; then
        ALL_SKILL_DIRS+=("project|$platform||$path")
    fi
}

_add_project_dir "$CLAUDE_PROJECT_SKILLS" "claude"
_add_project_dir "$CODEX_PROJECT_SKILLS" "codex"
_add_project_dir "$OPENCODE_PROJECT_SKILLS" "opencode"
_add_project_dir "$PI_PROJECT_SKILLS" "pi"

# --- Add plugin skill dirs ---
# Source of truth is installed_plugins.json. Each plugin's installPath points
# at the active version's directory; skills live at <installPath>/skills/ or
# <installPath>/.claude/skills/. Dedup by realpath so a plugin installed at
# both user and project scope (same installPath) is added once.
if [[ -f "$INSTALLED_PLUGINS_FILE" ]] && command -v python3 &>/dev/null; then
    while IFS='|' read -r _plugin_name _plugin_dir; do
        # Trailing CR strip: defense in depth next to the python-side
        # newline pin, for Windows pipe translation and CRLF path entries.
        _plugin_name="${_plugin_name%$'\r'}"
        _plugin_dir="${_plugin_dir%$'\r'}"
        [[ -n "$_plugin_dir" ]] || continue
        [[ -d "$_plugin_dir" ]] || continue
        ALL_SKILL_DIRS+=("plugin|claude|$_plugin_name|$_plugin_dir")
    done < <(python3 - "$INSTALLED_PLUGINS_FILE" <<'PYEOF'
import json, os, sys
# Pin LF on stdout: Windows python translates \n to \r\n in pipes, which
# would leave stray \r on every line the bash `read` loop consumes.
sys.stdout.reconfigure(newline="\n")
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
plugins = data.get("plugins")
if not isinstance(plugins, dict):
    sys.exit(0)
seen = set()
for key, instances in plugins.items():
    plugin_name = key.split("@", 1)[0]
    if not isinstance(instances, list):
        continue
    for inst in instances:
        if not isinstance(inst, dict):
            continue
        install_path = inst.get("installPath", "")
        if not install_path:
            continue
        for sub in ("skills", os.path.join(".claude", "skills")):
            candidate = os.path.join(install_path, sub)
            if os.path.isdir(candidate):
                rp = os.path.realpath(candidate)
                if rp in seen:
                    break
                seen.add(rp)
                # Forward slashes: this path flows back into bash, where
                # backslash forms fail [[ -d ]] on Windows.
                print(f"{plugin_name}|{candidate.replace(chr(92), '/')}")
                break
PYEOF
)
fi

# --- Add source skill dirs ---
# ~/.claude/sources/<source>/skills/<skill>/SKILL.md
if [[ -d "$PLUGIN_SOURCES" ]]; then
    for _source_dir in "$PLUGIN_SOURCES"/*/; do
        [[ -d "$_source_dir" ]] || continue
        _source_name=$(basename "$_source_dir")
        _source_skills="${_source_dir%/}/skills"
        [[ -d "$_source_skills" ]] || continue
        ALL_SKILL_DIRS+=("plugin-source|claude|$_source_name|$_source_skills")
    done
fi

# --- Add Pi package skills ---
# Pi distributes skills inside packages declared in settings.json
# (<agent-dir>/settings.json user-level, ./.pi/settings.json project-level):
#   npm:<name>[@version]  -> <agent-dir>/npm/node_modules/<name>
#   git:<host>/<owner>/<repo>[@ref] or https://<host>/<owner>/<repo>
#                         -> <agent-dir>/git/<host>/<owner>/<repo>
#   ./local/path          -> resolved against the settings file's directory
# Skill dirs come from the package.json "pi"."skills" manifest (globs
# allowed) or the conventional <package>/skills/ directory. These entries use
# scope "package" (qualified downstream to "pi-package") and are read-only:
# managed by `pi`, never edited or deleted by the greenskeeper.
if command -v python3 &>/dev/null; then
    while IFS='|' read -r _pi_kind _pi_scope _pi_ns _pi_dir; do
        # Trailing CR strip: defense in depth next to the python-side
        # newline pin, for Windows pipe translation and CRLF path entries.
        _pi_kind="${_pi_kind%$'\r'}"
        _pi_scope="${_pi_scope%$'\r'}"
        _pi_ns="${_pi_ns%$'\r'}"
        _pi_dir="${_pi_dir%$'\r'}"
        [[ -n "$_pi_dir" ]] || continue
        [[ -d "$_pi_dir" ]] || continue
        if [[ "$_pi_kind" == "pkg" ]]; then
            ALL_SKILL_DIRS+=("package|pi|$_pi_ns|$_pi_dir")
        else
            ALL_SKILL_DIRS+=("$_pi_scope|pi||$_pi_dir")
        fi
    done < <(PI_AGENT_DIR="$PI_AGENT_DIR" PI_GIT_ROOT="$PI_GIT_ROOT" PI_NPM_ROOT="$PI_NPM_ROOT" python3 <<'PYEOF'
import glob
import json
import os
import sys
# Pin LF on stdout: Windows python translates \n to \r\n in pipes, which
# would leave stray \r on every line the bash `read` loop consumes.
sys.stdout.reconfigure(newline="\n")

agent_dir = os.environ.get("PI_AGENT_DIR", "")
git_root = os.environ.get("PI_GIT_ROOT", "")
npm_root = os.environ.get("PI_NPM_ROOT", "")

# (settings file, base dir for relative paths, level)
candidates = []
if agent_dir:
    candidates.append((os.path.join(agent_dir, "settings.json"), agent_dir, "user"))
candidates.append((os.path.join(".pi", "settings.json"),
                   os.path.abspath(".pi"), "project"))

seen = set()

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def has_skill_md(d):
    return (os.path.isfile(os.path.join(d, "SKILL.md")) or
            os.path.isfile(os.path.join(d, "Skill.md")))

def emit(kind, scope_or_ns, path):
    # scope_or_ns is the package id for pkg entries, the scope for exp ones
    # Normalize to forward slashes: this path flows back into bash, where a
    # mixed "C:/...\\.../..." form fails [[ -d ]] and globbing. Windows
    # python accepts forward slashes everywhere, so this is lossless.
    path = os.path.normpath(path).replace("\\", "/")
    rp = os.path.realpath(path)
    if rp in seen:
        return
    seen.add(rp)
    if kind == "pkg":
        # kind|scope|namespace|dir — scope "package" qualifies to "pi-package"
        print("pkg|package|%s|%s" % (scope_or_ns, path))
    else:
        # exp lines: kind|scope|namespace|dir with an empty namespace field
        print("exp|%s||%s" % (scope_or_ns, path))

def strip_npm_ver(spec):
    # '@scope/name@1.0' -> '@scope/name'; 'name@1.0' -> 'name'
    if spec.startswith("@"):
        i = spec.find("@", 1)
        return spec[:i] if i != -1 else spec
    i = spec.find("@")
    return spec[:i] if i != -1 else spec

def resolve_package(source, settings_dir):
    # Returns (root_dir, package_id) or (None, None).
    if source.startswith("npm:"):
        name = strip_npm_ver(source[4:])
        if not name:
            return None, None
        return os.path.join(npm_root, name), "npm:" + name
    rest = None
    if source.startswith("git:"):
        rest = source[4:]
    elif "://" in source:
        rest = source.split("://", 1)[1]
    if rest is not None:
        rest = rest.split("@", 1)[0]
        if rest.endswith(".git"):
            rest = rest[:-4]
        if not rest:
            return None, None
        return os.path.join(git_root, rest), "git:" + rest
    # Local path, resolved against the settings file's directory.
    root = os.path.normpath(os.path.join(settings_dir, source))
    return root, "local:" + os.path.basename(os.path.abspath(root))

def skill_dirs_of_package(root):
    out = []
    man = load_json(os.path.join(root, "package.json")) or {}
    pi_man = man.get("pi") if isinstance(man, dict) else None
    entries = pi_man.get("skills") if isinstance(pi_man, dict) else None
    if entries:
        if isinstance(entries, str):
            entries = [entries]
        for e in entries:
            if not isinstance(e, str):
                continue
            p = os.path.join(root, e)
            if any(c in e for c in "*?["):
                for g in glob.glob(p, recursive=True):
                    if os.path.isdir(g):
                        out.append(g)
            elif os.path.isdir(p):
                out.append(p)
    else:
        d = os.path.join(root, "skills")
        if os.path.isdir(d):
            out.append(d)
    return out

for settings_path, settings_dir, level in candidates:
    data = load_json(settings_path)
    if not isinstance(data, dict):
        continue
    packages = data.get("packages") or []
    for p in packages:
        src = p.get("source") if isinstance(p, dict) else p
        if not isinstance(src, str) or not src:
            continue
        root, pid = resolve_package(src, settings_dir)
        if not root or not os.path.isdir(root):
            continue
        for d in skill_dirs_of_package(root):
            # A manifest entry pointing at the skill itself: register the
            # parent so the normal per-skill iteration picks it up.
            target = os.path.dirname(d) if has_skill_md(d) else d
            emit("pkg", pid, target)
    skills = data.get("skills") or []
    if isinstance(skills, str):
        skills = [skills]
    for e in skills:
        if not isinstance(e, str) or not e:
            continue
        if e.startswith(("!", "-")):
            continue
        if e.startswith("+"):
            e = e[1:]
        base = agent_dir if level == "user" else settings_dir
        paths = (glob.glob(os.path.join(base, e), recursive=True)
                 if any(c in e for c in "*?[")
                 else [os.path.join(base, e)])
        for g in paths:
            if os.path.isdir(g):
                target = os.path.dirname(g) if has_skill_md(g) else g
                emit("exp", "pi-" + level, target)
PYEOF
)
fi

# --- Detect which platforms are present ---
HAS_CLAUDE=false
HAS_CODEX=false
HAS_OPENCODE=false
HAS_PI=false
for entry in ${ALL_SKILL_DIRS[@]+"${ALL_SKILL_DIRS[@]}"}; do
    if [[ "$entry" == *"|claude|"* ]]; then
        HAS_CLAUDE=true
    elif [[ "$entry" == *"|codex|"* ]]; then
        HAS_CODEX=true
    elif [[ "$entry" == *"|opencode|"* ]]; then
        HAS_OPENCODE=true
    elif [[ "$entry" == *"|pi|"* ]]; then
        HAS_PI=true
    fi
done

# --- Helper: iterate all skill directories ---
# Usage: for_each_skill_dir <callback_function>
# Callback receives: dir scope platform namespace
# scope is "user", "project", "plugin", "plugin-source" or "package";
# consumers qualify non-claude scopes as "<platform>-<scope>" (codex-user,
# opencode-project, pi-package, ...). namespace is empty except for
# plugin/source/package entries. Existing callbacks that ignore the 4th arg
# continue to work.
for_each_skill_dir() {
    local callback="$1"
    for entry in ${ALL_SKILL_DIRS[@]+"${ALL_SKILL_DIRS[@]}"}; do
        local scope="${entry%%|*}"
        local rest="${entry#*|}"
        local platform="${rest%%|*}"
        rest="${rest#*|}"
        local namespace="${rest%%|*}"
        local path="${rest#*|}"
        "$callback" "$path" "$scope" "$platform" "$namespace"
    done
}

# --- Shared: extract the description from SKILL.md frontmatter ---
# Handles inline scalars AND block scalars. Skills with folded descriptions
# previously read as empty, which made the always-loaded token split report 0
# for them and hid them from duplicate detection.
#
# The block-scalar header is [|>] plus an optional chomp indicator (- or +) and
# an optional explicit indent digit — | |- |+ |2 >- >+ >2 >-2 … Enumerating only
# the four commonest forms left the rest parsed as literal one- or two-character
# descriptions.
extract_description() {
    local file="$1"
    awk '
        { sub(/\r$/, "") }
        NR==1 && /^---$/ {started=1; next}
        started && /^---$/ {exit}
        started && !block && /^description:/ {
            val=$0; sub(/^description:[[:space:]]*/, "", val); gsub(/"/, "", val)
            if (val=="" || val ~ /^[|>][-+]?[0-9]*$/ || val ~ /^[|>][0-9]*[-+]?$/) {block=1; next}
            print val; exit
        }
        started && block && /^[[:space:]]+/ {line=$0; sub(/^[[:space:]]+/, "", line); printf "%s ", line; next}
        started && block {exit}
    ' "$file" 2>/dev/null | sed 's/[[:space:]]*$//'
}

# --- Platform display ---
platform_label() {
    local label=""
    if [[ "$HAS_CLAUDE" == "true" ]]; then
        label="Claude Code"
    fi
    if [[ "$HAS_CODEX" == "true" ]]; then
        [[ -n "$label" ]] && label="$label + "
        label="${label}Codex"
    fi
    if [[ "$HAS_OPENCODE" == "true" ]]; then
        [[ -n "$label" ]] && label="$label + "
        label="${label}OpenCode"
    fi
    if [[ "$HAS_PI" == "true" ]]; then
        [[ -n "$label" ]] && label="$label + "
        label="${label}Pi"
    fi
    if [[ -z "$label" ]]; then
        label="none"
    fi
    echo "$label"
}
