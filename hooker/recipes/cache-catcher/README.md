# Cache Catcher

Monitor Claude Code prompt cache health in real time. Detects when `cache_creation_input_tokens` consistently exceeds `cache_read_input_tokens` — a sign of broken prompt caching that silently multiplies API costs.

## Installation

```bash
/plugin marketplace add https://github.com/treetank-net/hooker.git
/plugin install cache-catcher@hooker-marketplace
```

## How it works

Cache Catcher hooks into four Claude Code events:

- **SessionStart** — detects resumes, tracks idle gap for adaptive TTL
- **UserPromptSubmit** — resume guard blocks the first prompt when cache is likely cold (broken CC versions or long idle gap)
- **PostToolUse** — after each tool use, compares cache write vs read tokens in recent turns
- **Stop** — catches cache anomalies on text-only turns (no tool use)

If writes consistently exceed reads (configurable threshold), it warns the agent or blocks further tool use.

### Resume guard

On CC versions 2.1.69–2.1.92, prompt cache breaks on every session resume. Cache Catcher blocks the first prompt after resume with a clear warning and options:

- Press ↑ then Enter to proceed anyway
- Start a new session (`/exit`) for a clean cache
- Disable the guard via `cache-catcher config set resume_guard false`

The guard adapts: if bad cache is detected on a short resume, TTL drops to 5 min. If cache is healthy, TTL returns to 60 min.

## CLI

Type commands directly in Claude Code chat (e.g. `cache-catcher status`) or run the script from a terminal.

```bash
# List commands
cache-catcher help

# Show current session cache health
cache-catcher status

# Per-turn cache metrics
cache-catcher history

# All sessions overview
cache-catcher sessions
cache-catcher sessions -n 20   # wider window for status/ratio columns

# Live monitoring (real terminal only)
cache-catcher watch

# Show configuration (project override vs plugin default)
cache-catcher config
cache-catcher config show

# Create project override from plugin template
cache-catcher config init
cache-catcher config init --force   # overwrite existing

# Read / write single keys
cache-catcher config get threshold
cache-catcher config set mode block
cache-catcher config set resume_guard false

# Claude Code prompt prefixes: always "cache-catcher", plus optional extras
cache-catcher alias              # show built-in + extras from config
cache-catcher alias set cc       # also accept "cc status", "cc history", etc.
cache-catcher alias clear        # drop extras
```

### Options
- `-s, --session ID` — analyze specific session
- `-n, --last N` — last N turns for `status` / `history`; for `sessions`, the window used for Read/Creation/Ratio/Status (default 10)
- `-j, --json` — JSON output
- `-t, --threshold N` — override threshold
- `-p, --project DIR` — project root (where `.claude/` lives)

## Configuration

Defaults ship with the plugin as `config.yml`. **Per-project overrides** go in the repo root:

`.claude/cache-catcher.config.yml`

Optional: `.claude/cache-catcher.messages.yml` overrides `messages.yml` the same way.

Example override file:

```yaml
mode: warn          # warn or block
lookback: 3         # turns to analyze
threshold: 1.0      # creation/read ratio trigger
min_tokens: 5000    # ignore small writes
streak: 1           # bad turns before trigger
cooldown: 60        # seconds between warnings
ignore_first_turn: true
prompt_aliases: cc  # "cc status" works like "cache-catcher status"

# Resume guard
resume_guard: true          # block first prompt on resume if cache likely cold
cache_ttl_default: 60       # assumed cache TTL in minutes (adapts automatically)
cache_ttl_min: 5            # minimum TTL after bad cache detected
resume_guard_force_ttl: false  # true = use TTL even on known-broken CC versions
```

## Codex Compatibility

Cache Catcher is currently **Claude Code only**. Codex uses different cache telemetry and token reporting, so the cache health analysis does not apply. The `PostToolUse` and `Stop` hooks that Cache Catcher relies on are available in Codex, but the token fields in the transcript differ.

## Develop / test

```bash
bash src/hooker/recipes/cache-catcher/scripts/self-test.sh
```
