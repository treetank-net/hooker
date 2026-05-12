#!/bin/bash
# Cache Catcher — UserPromptSubmit interceptor
# 1. Resume guard: blocks first prompt if cache likely cold (adaptive TTL / broken CC version)
# 2. CLI: catches "cache-catcher <cmd>" and optional prompt_aliases.

INPUT=$(cat)

# Extract common fields
PROMPT=$(echo "$INPUT" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
SESSION_ID=$(echo "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
HOOK_CWD=$(echo "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
TRANSCRIPT=$(echo "$INPUT" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${HOOK_CWD:-$(pwd)}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"

# Global config (user's machine-wide settings)
if [ -f "${HOME}/.claude/cache-catcher.config.yml" ]; then
    CONFIG_FILE="${HOME}/.claude/cache-catcher.config.yml"
fi

# Project-level override (highest priority)
if [ -f "${PROJECT_DIR}/.claude/cache-catcher.config.yml" ]; then
    CONFIG_FILE="${PROJECT_DIR}/.claude/cache-catcher.config.yml"
fi

yml_get() {
    _v=$(sed -n "s/^${1}:[[:space:]]*\"\{0,1\}\([^\"]*\).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*$//;s/[[:space:]]*$//' | sed 's/^"\(.*\)"$/\1/')
    [ -n "$_v" ] && echo "$_v" || echo "${2}"
}

STATE_DIR="/tmp/cache-catcher"
mkdir -p "$STATE_DIR" 2>/dev/null
LOG="${STATE_DIR}/debug.log"
log() { echo "[$(date '+%H:%M:%S')] [prompt] $*" >> "$LOG"; }

# --- JSON escape helper ---
_cc_json_escape() {
    awk '{
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "\\r")
        printf "%s", (NR>1 ? "\\n" : "") $0
    }'
}

# =========================================================
# 1. RESUME GUARD
# =========================================================
if [ -n "$SESSION_ID" ]; then
    GUARD_ENABLED=$(yml_get resume_guard true)
    if [ "$GUARD_ENABLED" != "false" ]; then
        # Read adaptive TTL
        TTL_FILE="${STATE_DIR}/adaptive_ttl"
        CACHE_TTL=$(cat "$TTL_FILE" 2>/dev/null | tr -d '[:space:]')
        [ -z "$CACHE_TTL" ] && CACHE_TTL=$(yml_get cache_ttl_default 60)
        TTL_SECS=$((CACHE_TTL * 60))

        # Compute idle gap from last_active (works for both resume and idle sessions)
        SESSION_STATE="${STATE_DIR}/${SESSION_ID}.session"
        IDLE_GAP=0
        if [ -f "$SESSION_STATE" ]; then
            LAST_ACTIVE=$(sed -n 's/^last_active:[[:space:]]*//p' "$SESSION_STATE" 2>/dev/null | head -1)
            NOW=$(date +%s 2>/dev/null || echo 0)
            [ -n "$LAST_ACTIVE" ] && IDLE_GAP=$((NOW - LAST_ACTIVE))
        fi

        # Check for resume (additional: unpatched version always blocks on resume)
        RESUME_FILE="${STATE_DIR}/${SESSION_ID}.resumed"
        IS_RESUME=0
        [ -f "$RESUME_FILE" ] && IS_RESUME=1

        # Get CC version (from transcript or cache)
        CC_VER_CACHE="${STATE_DIR}/cc_version"
        CC_VERSION=$(cat "$CC_VER_CACHE" 2>/dev/null)
        if [ -f "$TRANSCRIPT" ]; then
            CC_VERSION=$(grep '"version":"' "$TRANSCRIPT" | tail -1 | sed -n 's/.*"version":"\([0-9][0-9.]*\)".*/\1/p')
            [ -n "$CC_VERSION" ] && echo "$CC_VERSION" > "$CC_VER_CACHE"
        fi

        # Check if version is in broken range (2.1.69+)
        FORCE_TTL=$(yml_get resume_guard_force_ttl false)
        IS_BROKEN=0
        if [ "$FORCE_TTL" != "true" ] && [ -n "$CC_VERSION" ]; then
            _major=$(echo "$CC_VERSION" | cut -d. -f1)
            _minor=$(echo "$CC_VERSION" | cut -d. -f2)
            _patch=$(echo "$CC_VERSION" | cut -d. -f3)
            if [ "$_major" = "2" ] && [ "$_minor" = "1" ] && [ "$_patch" -ge 69 ] 2>/dev/null; then
                IS_BROKEN=1
            fi
        fi

        # Decide whether to block
        SHOULD_BLOCK=0
        BLOCK_REASON=""
        if [ "$IS_RESUME" -eq 1 ] && [ "$IS_BROKEN" -eq 1 ]; then
            SHOULD_BLOCK=1
            BLOCK_REASON="unpatched"
        elif [ "$IDLE_GAP" -gt "$TTL_SECS" ] 2>/dev/null; then
            SHOULD_BLOCK=1
            BLOCK_REASON="ttl"
        fi

        if [ "$SHOULD_BLOCK" -eq 1 ]; then
            # Loop safety: if user sends exact same prompt again, let it through
            PROMPT_HASH=$(printf '%s' "$PROMPT" | cksum | awk '{print $1}')
            GUARD_FILE="${STATE_DIR}/${SESSION_ID}.guard"

            if [ -f "$GUARD_FILE" ]; then
                STORED_HASH=$(cat "$GUARD_FILE" 2>/dev/null)
                if [ "$STORED_HASH" = "$PROMPT_HASH" ]; then
                    rm -f "$GUARD_FILE"
                    log "Guard bypassed (same prompt confirmed). Letting through."
                    SHOULD_BLOCK=0
                fi
            fi

            if [ "$SHOULD_BLOCK" -eq 1 ]; then
                GAP_MIN=$(( (IDLE_GAP + 59) / 60 ))

                # Token estimate from last known state
                TOKEN_NOTE=""
                STATE_FILE_M="${STATE_DIR}/${SESSION_ID}.state"
                if [ -f "$STATE_FILE_M" ]; then
                    EST=$(sed -n 's/^last_creation:[[:space:]]*//p' "$STATE_FILE_M" 2>/dev/null | head -1)
                    [ -n "$EST" ] && TOKEN_NOTE="Estimated cost: ~${EST} creation tokens. "
                fi

                if [ "$BLOCK_REASON" = "unpatched" ]; then
                    WHY="Your CC version (${CC_VERSION}) has a known bug that breaks prompt cache on every resume."
                    FIX_HINT="Fix: https://www.npmjs.com/package/claude-code-cache-fix"
                else
                    WHY="Session idle for ${GAP_MIN} min (cache TTL: ${CACHE_TTL} min). Cache has likely expired."
                    FIX_HINT=""
                fi

                MSG=$(printf '⚠️  Cache Catcher: prompt cache is likely cold.\n\n%s\n%s%s\nWhat to do:\n  → Press ↑ then Enter to send the same message anyway\n  → Or start a new session (/exit) for a clean cache\n\nTo disable this warning, type this as your next message:\n  cache-catcher config set resume_guard false' \
                    "$WHY" "$TOKEN_NOTE" "$FIX_HINT")

                echo "$PROMPT_HASH" > "$GUARD_FILE"
                log "Blocked. reason=${BLOCK_REASON} gap=${IDLE_GAP}s ttl=${TTL_SECS}s broken=${IS_BROKEN} resume=${IS_RESUME} ver=${CC_VERSION}"

                ESCAPED=$(printf '%s' "$MSG" | _cc_json_escape)
                echo "{\"decision\": \"block\", \"reason\": \"${ESCAPED}\"}"
                exit 0
            fi
        else
            log "Guard: no block. broken=${IS_BROKEN} resume=${IS_RESUME} gap=${IDLE_GAP}s ttl=${TTL_SECS}s"
        fi
    fi
fi

# =========================================================
# 2. CLI COMMAND INTERCEPT
# =========================================================

# Resolve command prefix: cache-catcher always, then comma-separated prompt_aliases
PREFIX=""
case "$PROMPT" in
    cache-catcher|cache-catcher\ *) PREFIX=cache-catcher ;;
    *)
        ALIASES_RAW=$(yml_get prompt_aliases)
        OLD_IFS=$IFS
        IFS=','
        for _a in $ALIASES_RAW; do
            _a=$(echo "$_a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_a" ] && continue
            case "$PROMPT" in
                "${_a}"|"${_a}"\ *)
                    PREFIX=$_a
                    break
                    ;;
            esac
        done
        IFS=$OLD_IFS
        ;;
esac

[ -z "$PREFIX" ] && exit 0

CLI="${SCRIPT_DIR}/scripts/cache-catcher.sh"

if [ "$PROMPT" = "$PREFIX" ]; then
    CMD=""
else
    CMD="${PROMPT#"${PREFIX}"}"
    CMD=$(echo "$CMD" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi

# Run CLI, capture output (strip ANSI for clean block message)
# CACHE_CATCHER_FROM_CLAUDE_CODE: watch must not run here (infinite loop / no TTY)
ESC=$(printf '\033')
OUTPUT=$(CACHE_CATCHER_FROM_CLAUDE_CODE=1 bash "$CLI" -p "$PROJECT_DIR" $CMD 2>&1 | sed "s/${ESC}\[[0-9;]*m//g")

if [ -z "$OUTPUT" ]; then
    OUTPUT="cache-catcher: no output for '$CMD'"
fi

# Block prompt — show output to user, don't send to Claude
ESCAPED=$(printf '%s' "$OUTPUT" | _cc_json_escape)
echo "{\"decision\": \"block\", \"reason\": \"${ESCAPED}\"}"
