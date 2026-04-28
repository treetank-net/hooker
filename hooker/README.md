# Hooker - Universal Hook Injection Framework

Inject custom prompts, reminders, guardrails, and context into Claude Code (25+ hook events) and OpenAI Codex (5 hook events). Mix and match pre-built recipes or create your own with simple shell scripts. Now with standalone mode — recipes work without hooker installed.

## Installation

### Claude Code

```bash
# From GitHub marketplace
/plugin marketplace add https://github.com/treetank-net/hooker.git
/plugin install hooker@hooker-marketplace

# Or local
claude --plugin-dir /path/to/hooker
```

### OpenAI Codex

```bash
bash install-codex.sh
```

This registers the marketplace in `~/.agents/plugins/marketplace.json`. Restart Codex
and the plugin appears in `/plugins`. Update with `bash install-codex.sh --update`.

Then use the recipe skill to install hooks:

```
use the hooker recipe skill to install no-force-push-main
```

The skill detects Codex automatically and wires hooks in `.codex/hooks.json` instead of
Claude's `settings.json`. Hook files live in `.codex/hooker/` and `${CODEX_HOME}/hooker/`
with legacy fallback to `.claude/hooker/`.

## How It Works

```
Any hook event fires (e.g., Stop, PreToolUse, SessionStart...)
    ↓
inject.sh checks for: .claude/hooker/{EventName}.match.sh or .md
    ↓
Falls back to: plugin/templates/{EventName}.match.sh or .md
    ↓
Nothing found? → passthrough (no-op)
    ↓
Match script with output? → script controls everything
    ↓
Match script without output? → template controls the action
    ↓
Template only? → always fires
```

### Three Modes

| Mode | Files | Use when |
|------|-------|----------|
| **Static** | `.md` only | Always inject same content |
| **Conditional** | `.md` + `.match.sh` | Fire only when condition met |
| **Dynamic** | `.match.sh` only | Script decides everything at runtime |

## Commands

| Command | Description |
|---------|-------------|
| `/hooker:recipe` | Main hub — browse recipes, create hooks, install/remove |
| `/hooker:status` | Show active hooks |
| `/hooker:config` | Logging and reference |

## Recipes

Pre-built hook configurations. Install with `/hooker:recipe <name>`.

### Included Recipes

#### Safety

| Recipe | Hook | What it does |
|--------|------|-------------|
| **block-dangerous-commands** | PreToolUse | Blocks rm -rf, fork bombs, curl|sh, DROP TABLE, and other destructive bash commands. |
| **no-force-push-main** | PreToolUse | Blocks git push --force to main/master branches. |
| **protect-sensitive-files** | PreToolUse | Blocks reading or editing .env, SSH keys, credentials, and other sensitive files. |

#### Refactoring

| Recipe | Hook | What it does |
|--------|------|-------------|
| **refactor-move-csharp-smart** | PostToolUse, PostCompact, SessionStart | After mv of .cs files, updates namespace declarations and using statements across the project. Derives namespace from directory structure + .csproj. Pure bash/sed. |
| **refactor-move-go-simple** | PostToolUse, PostCompact, SessionStart | After mv of .go files, updates import paths across the project. Reads go.mod for module path. Pure bash/sed — no external dependencies (gorename not required). |
| **refactor-move-java-smart** | PostToolUse, PostCompact, SessionStart | After mv of .java files, updates package declarations and import statements across the project. Derives package from directory structure. Pure bash/sed. |
| **refactor-move-markdown** | PostToolUse, PostCompact, SessionStart | After mv of any file, updates relative links in .md files ([text](path) and image refs). Pure bash/sed — no external dependencies. |
| **refactor-move-php-smart** | PostToolUse, PostCompact, SessionStart | After mv of .php files, uses phpactor for AST-aware namespace/use rewriting. Reads composer.json PSR-4 mappings. Falls back to sed if phpactor unavailable. |
| **refactor-move-python-simple** | PostToolUse, PostCompact, SessionStart | After mv of .py files, updates import statements (from X import Y, import X) across the project. Pure bash/sed — no external dependencies. Best adapted as a project-specific hook. |
| **refactor-move-python-smart** | PostToolUse, PostCompact, SessionStart | After mv of .py files, uses rope for AST-aware import rewriting. Handles relative imports, from/import, __init__.py re-exports. Falls back to sed if rope unavailable. |
| **refactor-move-rust-smart** | PostToolUse, PostCompact, SessionStart | After mv of .rs files, updates mod declarations and use paths. Reads Cargo.toml for crate name. Handles mod.rs and inline modules. Optionally runs cargo fmt. Pure bash/sed. |
| **refactor-move-symbol** | PostToolUse, PostCompact, SessionStart | EXPERIMENTAL. Detects when a function/class/export is cut from one file and pasted into another (via two Edit calls). Tracks removals in state file, matches with additions, then suggests import updates. Uses Python for diff analysis. May produce false positives. |
| **refactor-move-ts-simple** | PostToolUse, PostCompact, SessionStart | After mv of .ts/.tsx/.js/.jsx files, updates import/require paths across the project. Reads tsconfig.json for baseUrl/path aliases. Requires python3 for reliable relative path computation (falls back to simpler approach without it). Best adapted as a project-specific hook. |
| **refactor-move-ts-smart** | PostToolUse, PostCompact, SessionStart | After mv of .ts/.tsx/.js/.jsx files, uses TypeScript Language Service API (getEditsForFileRename — same as VS Code) for AST-aware import rewriting. Handles path aliases, re-exports, barrel files. Requires typescript (global or local). Falls back to sed. |
| **refactor-move-universal** | PostToolUse, PostCompact, SessionStart | After mv of any file, finds and replaces old path references in all text files (config, YAML, Dockerfile, scripts, etc.). Catches what language-specific recipes miss. Pure bash/sed. |

#### Workflow

| Recipe | Hook | What it does |
|--------|------|-------------|
| **auto-checkpoint** | Stop | Creates a git checkpoint commit when Claude stops responding. Easy rollback of changes. |
| **auto-format** | PostToolUse | Runs the appropriate formatter (prettier, ruff, gofmt, etc.) after every file edit. |
| **ralph-wiggum** | SessionStart, Stop | Autonomous multi-iteration task execution with fresh context. Activates when RALPH_ITERATION env var is set by outer loop. |
| **require-changelog-before-tag** | PreToolUse | Blocks git tag and push --tags unless CHANGELOG.md was updated in the current commit or staging area. |

#### Context

| Recipe | Hook | What it does |
|--------|------|-------------|
| **agent-gets-claude-context** | SubagentStart | Injects CLAUDE.md and MEMORY.md into every subagent so they share the main session's project instructions and memory. |
| **agents-md-context** | SessionStart, PostCompact | Injects AGENTS.md content into session context on start and after compaction. Walks up from CWD to find the nearest AGENTS.md, respecting the convention used by multi-agent projects. |
| **compact-context** | PreCompact | Injects custom instructions into the compaction prompt. Lightweight alternative to the kompakt plugin — edit PreCompact.md to customize what the compactor preserves. |
| **git-context-on-start** | SessionStart | Injects current git branch, status, and recent commits on session start. |
| **hook-discovery** | UserPromptSubmit | Detects when user might want hooks/automation and suggests /hooker:recipe. |
| **reinject-after-compact** | SessionStart | Re-injects critical project context (from .claude/hooker/context.md) after compaction to prevent context loss. |

#### Quality

| Recipe | Hook | What it does |
|--------|------|-------------|
| **detect-lazy-code** | PostToolUse | Catches when Claude replaces code with comments like '// ... rest of implementation' or leaves vague TODO/FIXME placeholders. |
| **no-console-log** | PreToolUse | Blocks writing console.log statements. Uses declarative matcher only, no match script needed. |
| **no-dismiss-failures** | PostToolUse | After test/lint commands fail, injects a reminder that dismissing failures is unacceptable. Agent must investigate root cause, fix, or explain to user. |
| **remind-to-update-docs** | Stop | Context-aware reminder on stop — checks what was edited (code/docs/tests) and shows appropriate message from messages.yml. Only fires if Edit/Write/NotebookEdit was used in the last turn. |
| **skip-acknowledgments** | UserPromptSubmit | Stops Claude from opening with 'Great question!', 'You're right!', etc. Focus on the solution. |

#### Monitoring

| Recipe | Hook | What it does |
|--------|------|-------------|
| **behavior-watchdog** | UserPromptSubmit | Periodically and on frustration signals, silently reminds Claude to check if its behavior is causing issues and suggests /hooker:recipe as a fix. |
| **cache-catcher** | SessionStart, UserPromptSubmit, PostToolUse, Stop | Monitor Claude Code cache health. Warns or blocks when cache writes exceed reads, indicating broken prompt caching. |
| **dir-cleanup** | UserPromptSubmit | Auto-removes oldest files from configured directories when they exceed thresholds. DESTRUCTIVE — deletes files. Shares config with dir-watchdog (dir-watchdog.yml). Only acts on rules with action: cleanup. |
| **dir-watchdog** | UserPromptSubmit | Monitors directories for file bloat (too many files of same type). Warns about bloated directories — never deletes anything. Configure thresholds in dir-watchdog.yml. Use dir-cleanup for auto-removal. |
| **scheduled-tasks** | SessionStart, UserPromptSubmit, SessionEnd | Auto-installs/updates crontab from schedules.yml on session start. Saves results from headless sessions. Notifies about unread cron results in interactive sessions. |
| **session-guardian** | PostToolUseFailure, TaskCompleted, PostCompact, SessionEnd, SubagentStop | Lifecycle reminders: verify failed tools, check tests before task completion, re-inject context after compaction, remind to commit on session end, review subagent output. |
| **smart-session-notes** | PreCompact | Creates filtered markdown session notes before compaction. Configurable: include/exclude user messages, assistant text, errors, tool calls. Saves to .claude/hooker/session-notes.md. |

### Hooker vs Hookify

[Hookify](https://github.com/anthropics/claude-code/tree/main/plugins/hookify) is Anthropic's official guardrail plugin. It's the closest thing to Hooker — here's how they differ:

| | Hooker | Hookify |
|---|---|---|
| **Approach** | Imperative (bash scripts) | Declarative (markdown + regex) |
| **Hook coverage** | All 20+ hooks | 5 events (bash, file, prompt, stop, all) |
| **Logic** | Arbitrary bash — read files, check state, call APIs | Regex matching on predefined fields |
| **Context injection** | Yes (XML trick, hidden/visible) | No (warn/block only, always visible) |
| **AI-powered** | No | Yes (`/hookify` auto-generates rules from conversation) |
| **Dependencies** | None (POSIX sh/awk/sed) | Python 3 |
| **Config format** | Shell scripts + messages.yml | Markdown + YAML frontmatter |
| **Best for** | Complex workflows, context injection, lifecycle management | Quick guardrails, no-code rules |

**They're complementary, not competing.** Use hookify for simple "block this regex" rules. Use Hooker when you need scripting, context injection, transcript analysis, or hooks beyond PreToolUse/Stop.

### Other Plugins Worth Knowing

| Plugin | What it does | Hooks used | License |
|--------|-------------|------------|---------|
| [safety-net](https://github.com/kenryu42/claude-code-safety-net) | Production-grade bash guardrails. Python AST parser, recursive `sudo`/`bash -c` unwrapping, semantic git analysis, custom rules via JSON config, audit logging. 1285 lines of battle-tested logic. | PreToolUse (Bash) | MIT |
| [kompakt](https://gitlab.com/treetank/kompakt) | Custom summarization for `/compact`. Preserves conversation language, verbatim user messages, configurable presets. | PreCompact | MIT |
| [claudekit](https://github.com/carlrannaberg/claudekit) | Toolkit: typecheck, eslint, file-guard (195+ patterns), self-review, ban-any, codebase-map, thinking-level. | PreToolUse, PostToolUse, SessionStart, UserPromptSubmit, Stop | MIT |
| [parry](https://github.com/vaporif/parry) | ML-based prompt injection scanner using DeBERTa v3. Six-stage detection pipeline. | PreToolUse, PostToolUse, UserPromptSubmit | MIT |
| [Dippy](https://github.com/ldayton/Dippy) | AST-based bash auto-approval. Parses commands into syntax tree, 14,000+ tests. Reduces permission fatigue. | PreToolUse (Bash) | MIT |

Our included recipes (block-dangerous-commands, protect-sensitive-files) are lightweight alternatives for users who don't need the full power of these plugins.

### Community Inspirations — Not Yet Implemented

Ideas from the community that could become Hooker recipes.
See [NOTICES.md](NOTICES.md) for full attribution and license details.

| Idea | Hook | Source | License |
|------|------|--------|---------|
| Block hardcoded secrets in code | PostToolUse | [paddo.dev](https://paddo.dev/blog/claude-code-hooks-guardrails/) | Blog |
| Branch protection (no commits to main) | PreToolUse | [Cameron Westland](https://cameronwestland.com/building-my-first-claude-code-hooks-automating-the-workflow-i-actually-want/) | Blog |
| Production keyword warning | PreToolUse | [paddo.dev](https://paddo.dev/blog/claude-code-hooks-guardrails/) | Blog |
| Ruff lint + format for Python | PostToolUse | [TMYuan/ruff-claude-hook](https://github.com/TMYuan/ruff-claude-hook) | MIT |
| TypeScript type checking after edit | PostToolUse | [claudekit](https://github.com/carlrannaberg/claudekit) | MIT |
| Ban `any` types in TypeScript | PostToolUse | [claudekit](https://github.com/carlrannaberg/claudekit) | MIT |
| Lint gate before commit | PreToolUse | [Blake Crosley](https://blakecrosley.com/blog/claude-code-hooks-tutorial) | Blog |
| Enforce package manager (pnpm/npm) | PreToolUse | [Steve Kinney](https://stevekinney.com/courses/ai-development/claude-code-hook-examples) | Blog |
| Warn on test file modification | PostToolUse | [paddo.dev](https://paddo.dev/blog/claude-code-hooks-guardrails/) | Blog |
| Auto-run tests after edit | PostToolUse | [Blake Crosley](https://blakecrosley.com/blog/claude-code-hooks-tutorial) | Blog |
| Block PR unless tests pass | PreToolUse | [Official docs](https://code.claude.com/docs/en/hooks-guide) | Docs |
| Full test suite before stop | Stop | [claudekit](https://github.com/carlrannaberg/claudekit) | MIT |
| Require tests before task complete | TaskCompleted | [Official docs](https://code.claude.com/docs/en/hooks) | Docs |
| Auto-commit with prompt as message | Stop | [GitButler blog](https://blog.gitbutler.com/automate-your-ai-workflows-with-claude-code-hooks/) | Blog |
| Auto-commit after every file edit | PostToolUse | [bleepingswift](https://bleepingswift.com/blog/claude-code-auto-commit) | Blog |
| Session-isolated git branches | Pre/PostToolUse + Stop | [GitButler blog](https://blog.gitbutler.com/automate-your-ai-workflows-with-claude-code-hooks/) | Blog |
| Codebase map injection | UserPromptSubmit | [claudekit](https://github.com/carlrannaberg/claudekit) | MIT |
| Auto-refresh context every N prompts | UserPromptSubmit | [John Lindquist gist](https://gist.github.com/johnlindquist/23fac87f6bc589ddf354582837ec4ecc) | No license |
| Transcript backup before compaction | PreCompact | [disler/hooks-mastery](https://github.com/disler/claude-code-hooks-mastery) | No license |
| Self-review on stop | Stop | [claudekit](https://github.com/carlrannaberg/claudekit) | MIT |
| Desktop notification on stop | Stop | [Blake Crosley](https://blakecrosley.com/blog/claude-code-hooks-tutorial) | Blog |
| Slack notification on idle | Notification | [karanb192/claude-code-hooks](https://github.com/karanb192/claude-code-hooks) | MIT |
| Check TODOs on stop | Stop | [claudekit](https://github.com/carlrannaberg/claudekit) | MIT |
All of these can be implemented as Hooker recipes using `.match.sh` scripts with helpers.
See `/hooker:recipe` to create your own or install included ones.

## Match Script Helpers

Source `"${HOOKER_HELPERS}"` in your `.match.sh` scripts:

```bash
#!/bin/bash
source "${HOOKER_HELPERS}"
deny "Not allowed. Suggest alternative to user."
```

| Helper | Visibility | Effect |
|--------|------------|--------|
| `warn "msg"` | visible | Warning, doesn't block |
| `deny "msg"` | visible | Denies tool use |
| `allow "msg"` | visible | Auto-allows tool use |
| `ask "msg"` | visible | Escalates to user |
| `block "msg"` | visible | Blocks action |
| `remind "msg"` | visible | Blocks stop with reminder |
| `inject "text"` | **hidden** | Injects into Claude's context |
| `load_md "file"` | — | Loads file content (useful inside `inject()`) |

**Only `inject()` hides content from the user.** All JSON helpers (warn, deny, block, etc.) are always fully visible — Claude Code renders JSON fields as plaintext.

`<visible>` tags in `.md` templates show selected parts to user (rest is hidden via XML trick).

Env vars: `$HOOKER_EVENT`, `$HOOKER_TRANSCRIPT`, `$HOOKER_CWD`, `$HOOKER_HELPERS`

All scripts are cross-platform (Linux, macOS, Windows/Git Bash). No dependencies on python3, perl, or tac.

## All Hook Events

### Base hooks (plugin hooks.json — CC >= 2.1.68)

| Category | Hooks |
|----------|-------|
| Session | SessionStart, SessionEnd, Setup |
| Tools | PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest |
| Flow | UserPromptSubmit, Stop, TaskCompleted |
| Agents | SubagentStart, SubagentStop, TeammateIdle |
| Compact | PreCompact |
| Config | ConfigChange, WorktreeCreate, WorktreeRemove |
| MCP | Elicitation, ElicitationResult |
| Other | Notification |

### Overflow hooks (version-gated, added via settings.json)

| Hook | Min CC version |
|------|---------------|
| InstructionsLoaded | 2.1.69 |
| StopFailure | 2.1.78 |
| PostCompact | 2.1.78 |
| CwdChanged | 2.1.83 |
| FileChanged | 2.1.83 |
| TaskCreated | 2.1.84 |
| PermissionDenied | 2.1.89 |

## Project Structure

```
.claude-plugin/     Plugin manifest
commands/           Skills (slash commands)
hooks/              hooks.json → inject.sh
scripts/            inject.sh, helpers.sh (core engine)
recipes/            Pre-built hook configurations
templates/          Plugin-level default templates (intentionally empty)
src/                Build sources — NOT part of the runtime plugin
```

Most files in this repo (including this README) are **auto-generated** from sources in `src/`.
To make changes, edit files in `src/` and run `cd src && go run .` — do not edit root files directly.

The `src/` directory is not needed at runtime and should be excluded from plugin installation.

### `.pluginignore` (proposed standard)

No AI coding tool currently supports install-time file exclusion. We include a `.pluginignore` file as a proposed convention — see the file for details. If you're building a plugin installer or marketplace, please consider supporting it.

## Codex Compatibility

Hooker supports both Claude Code and OpenAI Codex. The build system generates dual plugin manifests (`.claude-plugin/` and `.codex-plugin/`) and converts commands into Codex skills automatically.

### What works in Codex

- **Skills/commands** — all three slash commands (`recipe`, `status`, `config`) are available in both runtimes as Codex skills (`skills/{name}/SKILL.md`)
- **Hook events** — Codex supports 5 of Claude Code's 25+ hook events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`
- **Recipes** — recipes that only use Codex-supported hooks work natively; others are unsupported

### Recipe compatibility

Each recipe's `recipe.json` includes a `compatibility` field (auto-detected at build time):

```json
{
  "compatibility": {
    "claude": "native",
    "codex": "native"
  }
}
```

Values: `native` (works out of the box), `unsupported` (uses hooks not available in Codex).

**18** recipes are Codex-native, **19** require Claude Code-only hooks.

## Known Issues

- **Newer hooks break older Claude Code versions:** Some hook events (e.g. `PostCompact`) were added in recent Claude Code releases. If `hooks.json` (plugin) or `settings.json` (standalone) contains an event the installed CC version doesn't recognize, Claude Code rejects **all hooks in that file** with an `invalid_key` error — not just the unsupported one. Downgrading Claude Code can trigger this unexpectedly. There is no graceful fallback — Claude Code validates all hook event names strictly at load time.
- **Stop hook disabled after error:** If a Stop hook returns an error (e.g. malformed output, XML in JSON reason), Claude Code may silently disable the Stop hook for the rest of the session. `/reload-plugins` does not fix this. You must fully restart Claude Code (`/exit` and start a new session). This only affects Stop — other hooks (PreToolUse, UserPromptSubmit, etc.) continue working.
- **XML trick doesn't work in JSON responses:** The `</local-command-stdout>` injection trick only works in raw stdout (e.g. `inject` type, PreCompact hooks). It does not work inside JSON `reason` or `systemMessage` fields — Claude Code renders them as literal text. This means `remind` and `block` content is always visible to the user.
- **Transcript field name:** Claude Code transcript JSONL uses `"name"` for tool names, not `"tool_name"`. Match scripts that grep transcripts must use `"name"`.

## License

MIT — see [NOTICES.md](NOTICES.md) for third-party attribution.
