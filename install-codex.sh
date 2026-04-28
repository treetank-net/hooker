#!/usr/bin/env bash

set -euo pipefail

MARKETPLACE_NAME="hooker-marketplace"
DEFAULT_REPO_URL="https://github.com/treetank-net/hooker.git"
DEFAULT_MARKETPLACE_ROOT="${HOME}/.codex/marketplaces"
MARKETPLACE_ROOT=""
REPO_URL=""
PLUGIN_NAME=""
ASSUME_YES=0
UPDATE_MODE=0

usage() {
    cat <<'EOF'
Usage: install-codex.sh [options]

Register Hooker marketplace for OpenAI Codex.

Clones the marketplace repo and registers it so Codex discovers plugins
automatically. Update with: install-codex.sh --update

Options:
  --repo URL            Git URL of the marketplace repo
  --marketplace PATH    Where to clone the repo (default: ~/.codex/marketplaces)
  --plugin NAME         Auto-enable a specific plugin after registration
  --update              Pull latest changes in existing clone
  --yes                 Non-interactive mode
  --help                Show this message

Examples:
  bash install-codex.sh
  bash install-codex.sh --plugin hooker
  bash install-codex.sh --update
  curl -fsSL <raw-script-url> | bash -s -- --plugin hooker
EOF
}

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)         REPO_URL="$2"; shift 2 ;;
        --marketplace)  MARKETPLACE_ROOT="$2"; shift 2 ;;
        --plugin)       PLUGIN_NAME="$2"; shift 2 ;;
        --update)       UPDATE_MODE=1; shift ;;
        --yes)          ASSUME_YES=1; shift ;;
        --help|-h)      usage; exit 0 ;;
        *)              fail "Unknown argument: $1" ;;
    esac
done

REPO_URL="${REPO_URL:-${DEFAULT_REPO_URL}}"
MARKETPLACE_ROOT="${MARKETPLACE_ROOT:-${DEFAULT_MARKETPLACE_ROOT}}"
CLONE_DIR="${MARKETPLACE_ROOT}/${MARKETPLACE_NAME}"
AGENTS_DIR="${HOME}/.agents/plugins"
AGENTS_MARKETPLACE="${AGENTS_DIR}/marketplace.json"

command -v git >/dev/null 2>&1 || fail "git is required"

# ─── Update mode ─────────────────────────────────────────────────────────────

if [ "$UPDATE_MODE" -eq 1 ]; then
    [ -d "$CLONE_DIR/.git" ] || fail "No existing clone at ${CLONE_DIR}. Run without --update first."
    log "Pulling latest changes..."
    git -C "$CLONE_DIR" pull --ff-only 2>&1
    log ""
    log "Updated. Restart Codex to pick up changes."
    exit 0
fi

# ─── Clone or refresh ────────────────────────────────────────────────────────

if [ -d "$CLONE_DIR/.git" ]; then
    log "Existing clone found at ${CLONE_DIR}"
    if [ "$ASSUME_YES" -eq 0 ]; then
        printf 'Pull latest changes? [Y/n] '
        read -r answer
        case "${answer:-Y}" in
            y|Y|yes|YES|"") git -C "$CLONE_DIR" pull --ff-only 2>&1 ;;
            *) log "Skipping pull." ;;
        esac
    else
        git -C "$CLONE_DIR" pull --ff-only 2>&1
    fi
else
    log "Cloning marketplace: ${REPO_URL}"
    mkdir -p "$MARKETPLACE_ROOT"
    git clone --depth=1 "$REPO_URL" "$CLONE_DIR" 2>&1
fi

# ─── Verify plugin structure ─────────────────────────────────────────────────

CODEX_PLUGINS=""
for dir in "$CLONE_DIR"/*/; do
    [ -f "${dir}.codex-plugin/plugin.json" ] && CODEX_PLUGINS="${CODEX_PLUGINS} $(basename "$dir")"
done
CODEX_PLUGINS="$(echo "$CODEX_PLUGINS" | sed 's/^ //')"

[ -n "$CODEX_PLUGINS" ] || fail "No Codex-compatible plugins found in ${CLONE_DIR}"

log ""
log "Codex-compatible plugins found: ${CODEX_PLUGINS}"

# ─── Check if repo already ships marketplace.json ────────────────────────────
# If the cloned repo has .agents/plugins/marketplace.json, use it directly.
# Otherwise generate one.

REPO_MARKETPLACE="${CLONE_DIR}/.agents/plugins/marketplace.json"

if [ -f "$REPO_MARKETPLACE" ]; then
    MARKETPLACE_SOURCE="$REPO_MARKETPLACE"
    log "Using marketplace.json from repo"
else
    # Generate marketplace.json from discovered plugins
    MARKETPLACE_SOURCE=""
    log "Generating marketplace.json from discovered plugins"
fi

# ─── Register marketplace ────────────────────────────────────────────────────
# Codex reads ~/.agents/plugins/marketplace.json automatically on startup.
# We either symlink to the repo's own marketplace.json or generate one.

mkdir -p "$AGENTS_DIR"

if [ -n "$MARKETPLACE_SOURCE" ]; then
    # Repo ships its own marketplace.json — but paths are relative to repo root.
    # We need to rewrite paths to be absolute since ~/.agents/plugins/ != clone dir.
    # Simplest: generate a wrapper that uses absolute paths.
    ENTRIES=""
    for name in $CODEX_PLUGINS; do
        [ -n "$ENTRIES" ] && ENTRIES="${ENTRIES},"
        ENTRIES="${ENTRIES}
    {
      \"name\": \"${name}\",
      \"source\": { \"source\": \"local\", \"path\": \"${CLONE_DIR}/${name}\" },
      \"policy\": { \"installation\": \"AVAILABLE\", \"authentication\": \"ON_INSTALL\" },
      \"category\": \"Coding\"
    }"
    done

    cat > "$AGENTS_MARKETPLACE" <<EOF
{
  "name": "${MARKETPLACE_NAME}",
  "interface": { "displayName": "Hooker Marketplace" },
  "plugins": [${ENTRIES}
  ]
}
EOF
else
    # Same generation, no repo marketplace to reference
    ENTRIES=""
    for name in $CODEX_PLUGINS; do
        [ -n "$ENTRIES" ] && ENTRIES="${ENTRIES},"
        ENTRIES="${ENTRIES}
    {
      \"name\": \"${name}\",
      \"source\": { \"source\": \"local\", \"path\": \"${CLONE_DIR}/${name}\" },
      \"policy\": { \"installation\": \"AVAILABLE\", \"authentication\": \"ON_INSTALL\" },
      \"category\": \"Coding\"
    }"
    done

    cat > "$AGENTS_MARKETPLACE" <<EOF
{
  "name": "${MARKETPLACE_NAME}",
  "interface": { "displayName": "Hooker Marketplace" },
  "plugins": [${ENTRIES}
  ]
}
EOF
fi

log "Registered marketplace: ${AGENTS_MARKETPLACE}"

# ─── Auto-enable plugin if requested ─────────────────────────────────────────

if [ -n "$PLUGIN_NAME" ]; then
    echo "$CODEX_PLUGINS" | tr ' ' '\n' | grep -qx "$PLUGIN_NAME" \
        || fail "Plugin '${PLUGIN_NAME}' not found. Available: ${CODEX_PLUGINS}"
    log "Plugin '${PLUGIN_NAME}' is available in the marketplace."
    log "After restarting Codex, install it via /plugins or ask Codex to use it."
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

log ""
log "Done!"
log ""
log "  Marketplace clone:  ${CLONE_DIR}"
log "  Marketplace config: ${AGENTS_MARKETPLACE}"
log "  Plugins available:  ${CODEX_PLUGINS}"
log ""
log "Next steps:"
log "  1. Restart Codex"
log "  2. Open /plugins — Hooker should appear"
log "  3. Install and use @hooker or /hooker:recipe"
log ""
log "To update later:"
log "  bash install-codex.sh --update"
log "  # or: cd ${CLONE_DIR} && git pull"
