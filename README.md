# Skills Greenskeeper

> Tinder for your agent skills. Swipe through your collection and delete what's wasting context, in seconds.

Works with **Claude Code**, **OpenAI Codex**, **OpenCode** and **Pi**. 9 commands plus a standalone `greenskeeper` launcher, zero dependencies.

> **Status (v1.9, October 2026): now multi-harness.**
>
> v1.8 noted that Claude Code covers the core use case natively (`/skill-doctor`, `/doctor`). That's still true for Claude-only trimming — but none of it sees Codex, OpenCode or Pi, and none of it deletes package-managed skills safely. v1.9 makes the greenskeeper the unified cleanup tool: one inventory, one usage model and one swipe deck across all four harnesses, with package/plugin skills flagged (never touched) and JSONC-safe config edits.

Scans every place a skill lives, in every harness: Claude user/project/plugin/source, Codex (`~/.agents/skills`), OpenCode (`~/.config/opencode/skills`, `.opencode/skills`) and Pi (`~/.pi/agent/skills`, `.pi/skills`, plus skills shipped inside Pi packages) — plus your subagents, commands, prompt templates, extensions and MCP servers. Surfaces duplicates, broken symlinks, unused skills, and connected-but-never-called MCP servers cluttering your context. Usage counts come from real session data in each harness: Claude history + transcripts, the OpenCode SQLite store, and Pi session files — including skills the agent auto-triggered.

## Commands

Every command works as a slash command (plugin install) and standalone
(`greenskeeper` launcher or `scripts/*.sh` directly). `mcp` and `scan` have no
slash command — they feed the reports and the swipe deck.

| Slash command | Standalone | What it does |
|---|---|---|
| `/janitor-report [--brief]` | `greenskeeper report [--brief]` | Health check: inventory, duplicates, broken skills. `--brief` for inventory only. |
| `/janitor-fix` | `greenskeeper fix [--dry-run] [--apply] [--prune]` | Preview (default) or apply fixes. `--prune` removes broken symlinks and empty dirs. |
| `/janitor-value` | `greenskeeper value [--weeks N] [--budget N] [--json]` | Honest token costs (always-loaded descriptions vs on-demand bodies) + usage, skills and subagents. |
| `/janitor-security` | `greenskeeper security [--path DIR] [--json]` | Heuristic scan for prompt injection, hidden instructions, and dangerous script patterns. (v1.6+) |
| `/janitor-discover` | `greenskeeper discover <query\|url> [--limit N] [--compare <name>] [--json]` | Search GitHub for skills, or check a URL before installing — now including a pre-install security scan. |
| `/janitor-swipe` | `greenskeeper swipe [--deck FILE] [--apply FILE]` | Interactive TUI — swipe keep/delete/skip through skills AND MCP servers, sorted most-likely-waste first. (v1.4+) |
| — | `greenskeeper mcp [--weeks N] [--json]` | MCP server inventory + real usage per harness. (v1.7+) |
| — | `greenskeeper scan` | Raw JSON inventory of everything (skills, agents, plugins, commands, prompts, extensions). |
| — | `greenskeeper dashboard [--no-open]` | Visual HTML dashboard with trends, health score and snapshot history (ported from upstream PR #3). |

Or use natural language: *"check my skills"*, *"which skills are wasting context?"*, *"find an n8n skill"*.

## Install

As a Claude Code plugin:

```
/plugin marketplace add juanmackie/skills-greenskeeper
/plugin install skills-greenskeeper
```

As a standalone program (any harness — the `greenskeeper` launcher calls the same
scripts the slash commands use):

```bash
git clone https://github.com/juanmackie/skills-greenskeeper
cd skills-greenskeeper
./greenskeeper report          # health check
./greenskeeper swipe           # interactive triage (needs a real terminal)
./greenskeeper --help          # all commands
```

On Windows, run it from Git Bash as above — or from CMD / PowerShell via the
`greenskeeper.cmd` shim (no Git Bash window needed for non-interactive commands):

```
greenskeeper report            # from CMD, inside the checkout directory
.\greenskeeper report          # from PowerShell, inside the checkout directory
```

Or via [skills.sh](https://skills.sh):

```bash
npx skills add juanmackie/skills-greenskeeper
```

Or clone directly:

```bash
git clone https://github.com/juanmackie/skills-greenskeeper ~/.claude/skills/skills-greenskeeper
```

## Quick start

New here? Three commands, five minutes:

1. **Health check** — what's installed, what's broken, what's duplicated:

   ```
   ./greenskeeper report
   ```

2. **Value** — what each skill costs in context vs whether you actually use it:

   ```
   ./greenskeeper value
   ```

3. **Swipe** — bulk-triage the wasters (`←` delete, `→` keep, `↓` skip).
   This one needs a real interactive terminal — run it in Git Bash / Terminal
   (or a console window via `greenskeeper.cmd`), not from inside an agent's shell
   tool:

   ```
   ./greenskeeper swipe
   ```

If anything looks suspicious, or before installing something new:

```
./greenskeeper security        # prompt-injection / malicious-pattern scan
./greenskeeper discover <url>  # overlap + security check BEFORE installing
```

Safety notes: `fix` and `swipe` only preview until you confirm (`--apply` / `y`).
Plugin, source and Pi-package skills are never edited — they're flagged with
their own removal command instead. Every MCP config edit writes a
timestamped `.bak` backup first.

First runs can take a few minutes on large collections (session-history and
database scans); later runs are faster.

## Security scan (v1.6)

A skill is text your agent trusts. Public research found prompt injection in roughly a third of tested community skills — so the greenskeeper now scans for the known bad shapes: instruction-override phrases, "don't tell the user" directives, instructions hidden in HTML comments or zero-width unicode, smuggled base64 payloads, and scripts that pipe the network into a shell or read credential stores.

```
/janitor-security          # audit everything installed
/janitor-discover <url>    # overlap + security check BEFORE installing
```

Verdicts are honest heuristics (PASS / REVIEW / RISK): a RISK means "read this before trusting it", not "malware". Calibrated for low noise — on a real 178-skill machine it flags 2, both genuinely worth reading.

## Swipe through your skills (v1.4)

Tinder-style triage for your skill collection. The deck is sorted heaviest-and-least-used first, so most users hit `← delete` through the top 5–10 cards and quit before reviewing everything.

```
!bash ~/.claude/skills/skills-greenskeeper/scripts/swipe.sh
```

(The `!` prefix runs in your terminal, not the Claude Code Bash tool — the TUI needs a real interactive stdin.)

Controls: `←` delete, `→` keep, `↓` skip, `u` undo, `i` inspect full description, `q` quit.

Plugin skills are flagged for review (you can't `rm` individual plugin skills — they belong to a plugin), and Pi package skills get a `pi remove <source>` hint for the same reason. User-scope skills stage for actual deletion, applied on `y` confirmation at the end.

Since v1.7 the deck also includes your MCP servers — see [MCP server triage](#mcp-server-triage-v17).

## MCP server triage (v1.7)

Skills aren't the only thing renting space in your context. Every connected MCP server loads
its tool schemas on every request, whether you call it or not.

The greenskeeper inventories every configured server — Claude user `~/.claude.json`, per-project entries,
project `.mcp.json`, and plugin-bundled; OpenCode global/project `opencode.json(c)` (comments
preserved on edit); Pi user/project `mcp.json` including `mcp-adapter.json` —
then cross-references real usage from each harness's session store (Claude
transcripts, the OpenCode SQLite database, Pi session files):

```
./greenskeeper mcp               # human-readable table
./greenskeeper mcp --weeks 12    # longer lookback
./greenskeeper mcp --json        # machine-readable (kind/cfg/pointer included)
```

```
=== Skills Greenskeeper - MCP Servers ===
Usage window: last 8 weeks of session transcripts

  Server                       Scope         Calls  Tools Last Used   Origin
  ──────────────────────────── ──────────── ────── ────── ─────────── ────────────
  design-tool                  mcp-user          0      0 never       ~/.claude.json
  deploy-tool                  mcp-plugin        0      0 never       plugin:deploy
  cms                          mcp-project      41      4 2026-07-02  ~/.claude.json

--- Unused in 8 weeks (2) ---
  design-tool (mcp-user) — configured in ~/.claude.json
  deploy-tool (mcp-plugin) — configured in plugin:deploy
```

No invented token numbers — MCP schemas live server-side, so the greenskeeper reports only what it
can prove: where the server is configured, how many distinct tools you actually called, how
often, and when last. Servers seen in transcripts but no longer configured are listed
separately.

Unused servers rank high in the swipe deck. Swiping one left removes the entry from its config
file with a timestamped `.bak` backup — OpenCode `.jsonc` files are edited by byte span, so
comments and formatting survive. Plugin-bundled servers and Pi package skills are flagged for
review instead (the greenskeeper never edits inside managed installs).

## Duplicate detection

The duplicate detector flags cross-scope overlaps, including plugins that re-implement a skill
you already had standalone:

```
=== Skills Greenskeeper - Duplicate Detection ===

--- Description Overlap (Jaccard > 30%) ---

  [98%] marketing-seo-audit <-> marketing-skills:seo-audit
        Scopes: user / plugin

  [100%] marketing-content-strategy <-> marketing-skills:content-strategy
        Scopes: user / plugin
```

Overlap is scored on descriptions (Jaccard), so it catches re-implementations that share no
filename and live in different scopes.

## Upgrading from v1.2

The five v1.2 aliases were removed in v1.5. Renames:

| v1.2 | now |
|---|---|
| `/janitor-audit` | `/janitor-report --brief` |
| `/janitor-usage` | `/janitor-value` |
| `/janitor-tokens` | `/janitor-value` |
| `/janitor-search` | `/janitor-discover` |
| `/janitor-precheck` | `/janitor-discover <url>` |

Full release notes: [CHANGELOG.md](CHANGELOG.md).

## Requirements

Bash, Python 3.7+, `curl`. No pip installs, no node modules.

## Contributing

PRs welcome. Each command is self-contained in `skills/janitor-*/SKILL.md` plus a sibling script in `scripts/`.

## Attribution

Skills Greenskeeper is a friendly fork of [Skills Janitor](https://github.com/khendzel/skills-janitor) by [Krzysztof Hendzel](https://github.com/khendzel) — the project that pioneered skill hygiene: Tinder-style triage, honest token costs, and prompt-injection scanning. It reached #4 of the day on Product Hunt and 120+ stars, with fixes contributed by [@nshonda](https://github.com/nshonda), [@lulzpid](https://github.com/lulzpid) and [@jerryhuangzq-lang](https://github.com/jerryhuangzq-lang).

Everything up to v1.8 is his work, kept here under the same MIT license (see [LICENSE](LICENSE)). The multi-harness support, standalone `greenskeeper` program, and everything since v1.9 is by [juanmackie](https://github.com/juanmackie).

## License

MIT
