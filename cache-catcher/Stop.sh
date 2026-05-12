#!/bin/bash
# Cache Catcher — Stop hook
# Catches cache anomalies on text-only turns after resume.
# If PostToolUse already fired (match.sh), this exits early — no double-check.


_cc_json_field() {
    sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

_cc_json_number() {
    sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p" | head -1
}

_cc_json_escape() {
    awk '{
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "\\r")
        printf "%s", (NR>1 ? "\\n" : "") $0
    }'
}

# --- Read CC hook JSON from stdin ---
INPUT=$(cat)

# Give CC time to flush the last transcript entry before reading the file
sleep 0.1

TRANSCRIPT=$(echo "$INPUT" | _cc_json_field transcript_path)
SESSION_ID=$(echo "$INPUT" | _cc_json_field session_id)

[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0
[ -z "$SESSION_ID" ] && exit 0

STATE_DIR="/tmp/cache-catcher"
mkdir -p "$STATE_DIR" 2>/dev/null
LOG="${STATE_DIR}/debug.log"

log() { echo "[$(date '+%H:%M:%S')] [stop] $*" >> "$LOG"; }

log "Stop fired. session=${SESSION_ID}"

# --- Update last_active (agent just finished its turn) ---
SESSION_STATE="${STATE_DIR}/${SESSION_ID}.session"
echo "last_active: $(date +%s)" > "$SESSION_STATE"
log "Updated last_active"

# --- Check if PostToolUse already handled this turn ---
PTU_FILE="${STATE_DIR}/${SESSION_ID}.ptu_fired"
if [ -f "$PTU_FILE" ]; then
    rm -f "$PTU_FILE" 2>/dev/null
    log "PostToolUse already fired. Skipping."
    exit 0
fi

# --- Check if this is a resume at all ---
RESUME_FILE="${STATE_DIR}/${SESSION_ID}.resumed"
if [ ! -f "$RESUME_FILE" ]; then
    log "No resume marker. Nothing to check."
    exit 0
fi

RESUME_TYPE=$(cat "$RESUME_FILE" 2>/dev/null)
rm -f "$RESUME_FILE" 2>/dev/null

if [ "$RESUME_TYPE" = "long" ]; then
    log "Long resume, text-only turn. Skipping (cache rebuild expected)."
    exit 0
fi

log "Short resume, no PostToolUse. Checking cache metrics."

# --- Config resolution (priority: project > global > recipe default) ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"

# Global config (user's machine-wide settings)
if [ -f "${HOME}/.claude/cache-catcher.config.yml" ]; then
    CONFIG_FILE="${HOME}/.claude/cache-catcher.config.yml"
fi

# Project-level override (highest priority)
if [ -f ".claude/cache-catcher.config.yml" ]; then
    CONFIG_FILE=".claude/cache-catcher.config.yml"
fi

yml_get() {
    sed -n "s/^${1}:[[:space:]]*\"\{0,1\}\([^\"]*\).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1 || echo "$2"
}

MSGS_FILE="${SCRIPT_DIR}/messages.yml"
if [ -f ".claude/cache-catcher.messages.yml" ]; then
    MSGS_FILE=".claude/cache-catcher.messages.yml"
fi

msg_get() {
    sed -n "s/^${1}:[[:space:]]*\"\{0,1\}\([^\"]*\).*/\1/p" "$MSGS_FILE" 2>/dev/null | head -1 || echo "$2"
}

MODE="$(yml_get mode warn)"
LOOKBACK="$(yml_get lookback 3)"
THRESHOLD="$(yml_get threshold 1.0)"
MIN_TOKENS="$(yml_get min_tokens 5000)"
STREAK="$(yml_get streak 1)"
IGNORE_FIRST="$(yml_get ignore_first_turn true)"

# --- Extract cache metrics from recent assistant turns ---
USAGE_DATA=$(grep '"type":"assistant"' "$TRANSCRIPT" | \
    grep '"usage"' | \
    tail -n "$LOOKBACK")

[ -z "$USAGE_DATA" ] && { log "No usage data."; exit 0; }

TOTAL_TURNS=$(grep -c '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null || echo 0)
if [ "$IGNORE_FIRST" = "true" ] && [ "$TOTAL_TURNS" -le 1 ]; then
    exit 0
fi

# Parse turns
TMP_FILE="${STATE_DIR}/${SESSION_ID}.tmp"

SKIP_FIRST=0
if [ "$IGNORE_FIRST" = "true" ]; then
    FIRST_OFFSET=$((TOTAL_TURNS - LOOKBACK))
    [ "$FIRST_OFFSET" -le 0 ] && SKIP_FIRST=1
fi

AFTER_RESUME=0
echo "$USAGE_DATA" | while IFS= read -r LINE; do
    [ -z "$LINE" ] && continue
    CREATION=$(echo "$LINE" | _cc_json_number cache_creation_input_tokens)
    READ=$(echo "$LINE" | _cc_json_number cache_read_input_tokens)
    CREATION="${CREATION:-0}"
    READ="${READ:-0}"

    if [ "$SKIP_FIRST" -eq 1 ]; then
        SKIP_FIRST=0
        continue
    fi

    # Resume detection: skip empty turns (boundary) and next turn (cache rebuild)
    if [ "$CREATION" -eq 0 ] 2>/dev/null && [ "$READ" -eq 0 ] 2>/dev/null; then
        AFTER_RESUME=1
        continue
    fi
    if [ "$AFTER_RESUME" -eq 1 ]; then
        AFTER_RESUME=0
        continue
    fi

    echo "${CREATION}:${READ}"
done > "$TMP_FILE" 2>/dev/null

# --- Analyze ---
BAD_COUNT=0
LAST_BAD_C=0
LAST_BAD_R=0
TURN_COUNT=0

while IFS=: read -r C R; do
    [ -z "$C" ] && continue
    TURN_COUNT=$((TURN_COUNT + 1))

    [ "$C" -lt "$MIN_TOKENS" ] 2>/dev/null && continue

    IS_BAD=0
    if [ "$R" -eq 0 ] 2>/dev/null; then
        IS_BAD=1
    else
        C_SCALED=$((C * 1000))
        T_INT=$(echo "$THRESHOLD" | awk '{printf "%d", $1 * 1000}')
        R_SCALED=$((R * T_INT))
        [ "$C_SCALED" -gt "$R_SCALED" ] 2>/dev/null && IS_BAD=1
    fi

    if [ "$IS_BAD" -eq 1 ]; then
        BAD_COUNT=$((BAD_COUNT + 1))
        LAST_BAD_C=$C
        LAST_BAD_R=$R
    fi
done < "$TMP_FILE"

rm -f "$TMP_FILE" 2>/dev/null

log "Analysis: turns=${TURN_COUNT} bad=${BAD_COUNT} streak_threshold=${STREAK} last_bad_creation=${LAST_BAD_C} last_bad_read=${LAST_BAD_R}"

# --- Adaptive TTL update ---
TTL_FILE="${STATE_DIR}/adaptive_ttl"
TTL_FLAG="${STATE_DIR}/${SESSION_ID}.ttl_updated"
if [ ! -f "$TTL_FLAG" ]; then
    TTL_MAX="$(yml_get cache_ttl_default 60)"
    TTL_MIN_V="$(yml_get cache_ttl_min 5)"
    if [ "$BAD_COUNT" -ge "$STREAK" ] 2>/dev/null; then
        echo "$TTL_MIN_V" > "$TTL_FILE"
        log "Adaptive TTL → ${TTL_MIN_V}min (bad cache)"
    else
        echo "$TTL_MAX" > "$TTL_FILE"
        log "Adaptive TTL → ${TTL_MAX}min (good cache)"
    fi
    touch "$TTL_FLAG"
fi

[ "$TURN_COUNT" -eq 0 ] && { log "No turns to analyze."; exit 0; }
[ "$BAD_COUNT" -lt "$STREAK" ] 2>/dev/null && { log "Bad count ${BAD_COUNT} < streak ${STREAK}. No alert."; exit 0; }

# --- Calculate ratio ---
if [ "$LAST_BAD_R" -gt 0 ] 2>/dev/null; then
    RATIO=$(awk "BEGIN{printf \"%.1f\", ${LAST_BAD_C}/${LAST_BAD_R}}")
else
    RATIO="inf"
fi

log "ALERT (Stop)! mode=${MODE} ratio=${RATIO} bad=${BAD_COUNT}"

MSG_WARNING=$(msg_get warning "CACHE ANOMALY: cache writes exceed reads. Ratio: ${RATIO}x")
MSG_WARNING="${MSG_WARNING//\{creation\}/$LAST_BAD_C}"
MSG_WARNING="${MSG_WARNING//\{read\}/$LAST_BAD_R}"
MSG_WARNING="${MSG_WARNING//\{ratio\}/$RATIO}"
MSG_WARNING="${MSG_WARNING//\{count\}/$BAD_COUNT}"

# Stop = stop. Output warning as systemMessage so CC shows it, but don't block.
ESCAPED=$(echo "$MSG_WARNING" | _cc_json_escape)
echo "{\"systemMessage\":\"${ESCAPED}\"}"
exit 0
