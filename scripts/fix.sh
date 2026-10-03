#!/bin/bash
# Skills Greenskeeper - Auto-Fix Common Issues
# Fixes frontmatter problems, missing fields, and naming mismatches
# Safe by default: --dry-run mode unless --apply is passed

set -euo pipefail

command -v python3 &>/dev/null || { echo "ERROR: python3 required" >&2; exit 1; }

# --- Load platform paths ---
source "$(dirname "$0")/paths.sh"

# Same data dir as usage/tokencost/search (previously this wrote into
# ~/.claude/skills/skills-greenskeeper/data, creating a fake skill directory).
DATA_DIR="$(cd "$(dirname "$0")/.." && pwd)/data"
CHANGELOG="$DATA_DIR/changelog.log"

DRY_RUN=true
APPLY=false
PRUNE=false

for arg in "$@"; do
    case "$arg" in
        --apply) DRY_RUN=false; APPLY=true ;;
        --dry-run) DRY_RUN=true ;;
        --prune) PRUNE=true ;;
        -h|--help)
            echo "Usage: fix.sh [--dry-run] [--apply] [--prune]"
            echo ""
            echo "Preview (default) or apply frontmatter fixes across writable"
            echo "skills; --prune also removes broken symlinks and empty dirs."
            echo "Plugin, source and package-managed skills are never modified."
            exit 0
            ;;
    esac
done

mkdir -p "$DATA_DIR"

FIXES=0
SKIPPED=0

log_change() {
    local skill="$1"
    local action="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] $skill: $action"
    else
        echo "  [FIXED]   $skill: $action"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $skill: $action" >> "$CHANGELOG"
    fi
    ((FIXES++)) || true
}

fix_skill() {
    local path="$1"
    local scope="$2"
    local name
    name=$(basename "$path")

    # Skip self
    [[ "$name" == "skills-greenskeeper" ]] && return

    # Skip broken symlinks
    if [[ -L "$path" && ! -e "$path" ]]; then
        echo "  [SKIP]    $name: Broken symlink - remove manually"
        ((SKIPPED++)) || true
        return
    fi

    # Any other symlink resolves outside this scan root - to a plugin
    # marketplace clone, the codex dir, or a user repo. The "/plugins/" check
    # below inspects this path string only, so it never sees the real target
    # and writing would dirty the upstream source instead.
    if [[ -L "$path" ]]; then
        echo "  [SKIP]    $name: symlink -> $(readlink "$path") - edit at source"
        ((SKIPPED++)) || true
        return
    fi

    # Find skill file
    local skill_file=""
    [[ -f "$path/SKILL.md" ]] && skill_file="$path/SKILL.md"
    [[ -f "$path/Skill.md" ]] && skill_file="$path/Skill.md"

    if [[ -z "$skill_file" ]]; then
        echo "  [SKIP]    $name: No SKILL.md found - create manually"
        ((SKIPPED++)) || true
        return
    fi

    # Skip plugin/marketplace skills
    if [[ "$path" == *"/plugins/"* || "$path" == *"/sources/"* ]]; then
        echo "  [SKIP]    $name: Plugin/marketplace skill - don't modify"
        ((SKIPPED++)) || true
        return
    fi

    # Skip package-managed skills (Pi npm/git packages): the package manager
    # owns these files, edits would be overwritten on update. The scope check
    # in the scan loop below is the primary guard; this path check is defense
    # in depth for symlinked or nested layouts.
    if [[ "$path" == *"/node_modules/"* || "$path" == *"/agent/git/"* ]]; then
        echo "  [SKIP]    $name: Package-managed skill - edit at the package source"
        ((SKIPPED++)) || true
        return
    fi

    local content
    content=$(cat "$skill_file")
    local modified=false
    local new_content="$content"

    # Fix 1: Add missing opening frontmatter delimiter
    local first_line
    # tr -d '\r': a CRLF file's first line is "---\r", which is a perfectly good
    # opening delimiter. Comparing it raw made this branch fire on every CRLF
    # skill and prepend a second "---" above the real one.
    first_line=$(head -1 "$skill_file" | tr -d '\r')
    if [[ "$first_line" != "---" ]]; then
        # Check if it looks like frontmatter without delimiters (has name: or description:)
        if head -5 "$skill_file" | grep -qE '^(name|description|version):'; then
            new_content="---
$new_content"
            # Find where frontmatter-like content ends and add closing ---.
            # awk, not `sed Na\` — BSD sed glues the appended line onto the
            # following one (no trailing newline), corrupting the file.
            local fm_end
            fm_end=$(echo "$new_content" | awk 'NR==1{next} NR>1 && !/^[a-z_]+:/ && !/^---\r?$/ && !/^[[:space:]]*$/{print NR-1; exit}')
            if [[ -n "$fm_end" && "$fm_end" -gt 1 ]]; then
                new_content=$(echo "$new_content" | awk -v n="$fm_end" 'NR==n {print; print "---"; next} {print}')
            fi
            modified=true
            log_change "$name" "Added missing frontmatter delimiters (---)"
        fi
    fi

    # Fix 2: Add missing closing frontmatter delimiter
    if head -1 "$skill_file" | grep -q '^---'; then
        local has_close
        has_close=$(awk 'NR>1 && /^---\r?$/{print "yes"; exit}' "$skill_file")
        if [[ -z "$has_close" ]]; then
            # Find end of the LEADING frontmatter run only. The old version
            # scanned the whole file for `key:` lines, so a body line like
            # `usage: run the tool` pushed the closing --- past the body,
            # swallowing everything above it into frontmatter.
            local insert_after
            insert_after=$(awk '
                NR==1 {next}
                /^[a-zA-Z_-]+:/ {last=NR; next}
                /^[[:space:]]+[^[:space:]]/ {next}
                /^[[:space:]]*$/ {next}
                {exit}
                END {if (last) print last}
            ' "$skill_file")
            if [[ -n "$insert_after" ]]; then
                # awk, not `sed Na\` — see BSD sed note in Fix 1
                new_content=$(echo "$new_content" | awk -v n="$insert_after" 'NR==n {print; print "---"; next} {print}')
                modified=true
                log_change "$name" "Added missing closing --- delimiter"
            fi
        fi
    fi

    # Fix 3: Add template description if empty
    # Re-parse after potential delimiter fixes
    if echo "$new_content" | head -1 | grep -q '^---'; then
        local frontmatter
        frontmatter=$(echo "$new_content" | awk 'NR==1 && /^---\r?$/{next} /^---\r?$/{exit} {print}')

        local has_desc
        if echo "$frontmatter" | grep -q '^description:' 2>/dev/null; then has_desc=1; else has_desc=0; fi

        # Template description injected below. All edits use awk anchored to
        # the FIRST match INSIDE the frontmatter only — the previous sed
        # variants (a) matched every `^name:`/`^description:` line including
        # ones in the skill BODY (docs that show example frontmatter), and
        # (b) on BSD sed glued the appended text onto the next line,
        # producing `description: "..."---` and an unclosed frontmatter.
        local desc_template
        desc_template="description: \"Use when the user wants to use $name. Add specific trigger phrases here.\""

        if [[ "$has_desc" -eq 0 ]]; then
            # Add description after name field or as first frontmatter field
            local has_name
            if echo "$frontmatter" | grep -q '^name:' 2>/dev/null; then has_name=1; else has_name=0; fi
            if [[ "$has_name" -gt 0 ]]; then
                new_content=$(echo "$new_content" | awk -v tmpl="$desc_template" '
                    NR>1 && /^---\r?$/ { fm_done=1 }
                    !fm_done && !ins && /^name:/ { print; print tmpl; ins=1; next }
                    { print }
                ')
            else
                new_content=$(echo "$new_content" | awk -v tmpl="$desc_template" '
                    NR==1 { print; print tmpl; next }
                    { print }
                ')
            fi
            modified=true
            log_change "$name" "Added template description field"
        else
            # Check if description is empty
            local desc_value
            desc_value=$(echo "$frontmatter" | grep '^description:' | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs 2>/dev/null || echo "")
            if [[ -z "$desc_value" ]]; then
                # Replace only the first frontmatter description line
                new_content=$(echo "$new_content" | awk -v tmpl="$desc_template" '
                    NR>1 && /^---\r?$/ { fm_done=1 }
                    !fm_done && !rep && /^description:/ { print tmpl; rep=1; next }
                    { print }
                ')
                modified=true
                log_change "$name" "Filled empty description with template"
            fi
        fi

        # Fix 4: Add missing version field
        # Recognize both top-level `version:` and nested `metadata.version` (the
        # canonical layout used by skills installed via `npx skills add`).
        # Without the nested check, --apply would inject a duplicate top-level
        # version: line into every modern skill, corrupting the frontmatter.
        local has_version=0 has_metadata=0
        if echo "$frontmatter" | grep -q '^version:' 2>/dev/null; then
            has_version=1
        elif echo "$frontmatter" | grep -qE '^[[:space:]]+version:[[:space:]]' 2>/dev/null; then
            has_version=1
        fi
        if echo "$frontmatter" | grep -q '^metadata:' 2>/dev/null; then
            has_metadata=1
        fi
        if [[ "$has_version" -eq 0 && "$has_metadata" -eq 1 ]]; then
            # Existing `metadata:` block but no version under it — auto-injection
            # would risk producing duplicate or malformed metadata blocks.
            # Surface this for manual review instead of attempting a fix.
            log_change "$name" "metadata: block exists but version missing — add 'version: \"1.0.0\"' under it manually"
        elif [[ "$has_version" -eq 0 ]]; then
            # Insert before the frontmatter's closing `---` rather than after a
            # named key. `description: >` and `description: |` are block-scalar
            # headers: splicing a new key directly after one ends the scalar
            # early, so the original description lines fold into the injected
            # mapping and the frontmatter stops being valid YAML.
            # awk is used instead of `sed a\` because BSD sed (macOS) does not
            # insert a trailing newline after the appended block, which makes
            # the following line (typically `---`) collide with the inserted text.
            # [[:space:]]* rather than a bare $ so the delimiter is still found
            # in a CRLF file, where the line reads `---\r`. CR is in the POSIX
            # space class, so this matches LF and CRLF alike.
            local patched
            patched=$(echo "$new_content" | awk '
                NR > 1 && /^---[[:space:]]*$/ && !done {
                    print "metadata:"
                    print "  version: \"1.0.0\""
                    done = 1
                }
                { print }
            ')
            # No closing delimiter (Fix 2 could not locate one) leaves the
            # content untouched; only report a fix when something changed.
            if [[ "$patched" != "$new_content" ]]; then
                new_content="$patched"
                modified=true
                log_change "$name" "Added missing metadata.version field (1.0.0)"
            fi
        fi
    fi

    # Apply changes
    if [[ "$modified" == "true" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            echo "$new_content" > "$skill_file"
        fi
    fi
}

echo "=== Skills Greenskeeper - Auto-Fix ==="
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Mode: DRY RUN (use --apply to make changes)"
else
    echo "Mode: APPLY (changes will be written)"
fi
echo ""

echo "--- Fix: user/project skills across all harnesses ---"
_fix_seen=""
_fix_first=true
_fix_iter() {
    local parent_dir="$1" scope="$2" _platform="$3"
    # Never fix plugin, source, or package-managed skills.
    [[ "$scope" == "plugin" || "$scope" == "plugin-source" || "$scope" == "package" ]] && return 0
    local label="$scope" plat_disp=""
    [[ "$_platform" != "claude" ]] && label="${_platform}-${scope}"
    case "$_platform" in
        codex) plat_disp="Codex " ;;
        opencode) plat_disp="OpenCode " ;;
        pi) plat_disp="Pi " ;;
    esac
    local scope_disp="$scope"
    case "$scope" in
        user) scope_disp="User" ;;
        project) scope_disp="Project" ;;
    esac
    local header="${plat_disp}${scope_disp}"
    local real_dir
    real_dir=$(cd "$parent_dir" 2>/dev/null && pwd -P || echo "$parent_dir")
    case "|$_fix_seen|" in *"|$real_dir|"*) return 0 ;; esac
    _fix_seen="$_fix_seen|$real_dir"
    if [[ "$_fix_first" == "true" ]]; then
        _fix_first=false
    else
        echo ""
    fi
    echo "--- $header Skills ($parent_dir) ---"
    for skill_dir in "$parent_dir"/*; do
        [[ -d "$skill_dir" || -L "$skill_dir" ]] || continue
        fix_skill "${skill_dir%/}" "$label"
    done
}
for_each_skill_dir _fix_iter

# --- Prune mode ---
PRUNED=0
if [[ "$PRUNE" == "true" ]]; then
    echo ""
    echo "--- Prune: Finding broken/orphaned skills ---"

    prune_dir() {
        local dir="$1"
        local scope="$2"
        [[ -d "$dir" ]] || return 0

        # No trailing slash on the glob: `"$dir"/*/` only matches entries that
        # RESOLVE to directories, so broken symlinks were invisible and the
        # advertised "removes broken symlinks" never fired.
        for skill_dir in "$dir"/*; do
            [[ -d "$skill_dir" || -L "$skill_dir" ]] || continue
            local name
            name=$(basename "$skill_dir")
            [[ "$name" == "skills-greenskeeper" ]] && continue

            local path="${skill_dir%/}"

            # Check broken symlinks
            if [[ -L "$path" && ! -e "$path" ]]; then
                local target
                target=$(readlink "$path" 2>/dev/null || echo "unknown")
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "  [DRY RUN] $name: Broken symlink -> $target (would remove)"
                else
                    rm -f "$path"
                    echo "  [PRUNED]  $name: Removed broken symlink -> $target"
                    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $name: Pruned broken symlink -> $target" >> "$CHANGELOG"
                fi
                ((PRUNED++)) || true
                continue
            fi

            # Check empty directories (no SKILL.md)
            if [[ -d "$path" ]]; then
                local has_skill=false
                [[ -f "$path/SKILL.md" ]] && has_skill=true
                [[ -f "$path/Skill.md" ]] && has_skill=true

                if [[ "$has_skill" == "false" ]]; then
                    local file_count
                    file_count=$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$file_count" -eq 0 ]]; then
                        if [[ "$DRY_RUN" == "true" ]]; then
                            echo "  [DRY RUN] $name: Empty directory (would remove)"
                        else
                            rm -rf "$path"
                            echo "  [PRUNED]  $name: Removed empty directory"
                            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $name: Pruned empty directory" >> "$CHANGELOG"
                        fi
                        ((PRUNED++)) || true
                    else
                        echo "  [SKIP]    $name: No SKILL.md but has $file_count files (review manually)"
                    fi
                fi
            fi
        done
    }

    _prune_seen=""
    _prune_iter() {
        local parent_dir="$1" scope="$2" _platform="$3"
        # Never prune plugin, source, or package-managed skills.
        [[ "$scope" == "plugin" || "$scope" == "plugin-source" || "$scope" == "package" ]] && return 0
        local label="$scope"
        [[ "$_platform" != "claude" ]] && label="${_platform}-${scope}"
        local real_dir
        real_dir=$(cd "$parent_dir" 2>/dev/null && pwd -P || echo "$parent_dir")
        case "|$_prune_seen|" in *"|$real_dir|"*) return 0 ;; esac
        _prune_seen="$_prune_seen|$real_dir"
        prune_dir "$parent_dir" "$label"
    }
    for_each_skill_dir _prune_iter

    if [[ "$PRUNED" -eq 0 ]]; then
        echo "  No broken or orphaned skills found."
    fi
fi

echo ""
echo "=== Summary ==="
echo "  Fixable issues: $FIXES"
echo "  Skipped:        $SKIPPED"
if [[ "$PRUNE" == "true" ]]; then
    echo "  Prunable:       $PRUNED"
fi
TOTAL=$((FIXES + PRUNED))
if [[ "$DRY_RUN" == "true" && "$TOTAL" -gt 0 ]]; then
    echo ""
    echo "  Run with --apply to make these changes."
fi
