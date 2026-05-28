#!/usr/bin/env bash
# claude-backup.sh — back up Claude Code CLI + Claude Desktop (incl. Cowork) state on macOS
#
# Usage:
#   ./claude-backup.sh                       # writes ~/claude-migration-YYYYMMDD-HHMMSS.tar.gz
#   ./claude-backup.sh /path/to/output.tar.gz
#
# What it includes:
#   - Claude Code CLI: ~/.claude.json, ~/.claude/ (config, projects/auto-memory, plugins, agents,
#     skills, statusline, tasks, plans, settings, file-history)
#   - Claude Desktop: claude_desktop_config.json (MCP servers), Preferences, config.json,
#     installed Claude Extensions (MCP) and their settings, Cowork local-agent-mode sessions,
#     claude-code-sessions, window/bridge/buddy state files
#   - Shell env vars that mention CLAUDE_* / ANTHROPIC_*
#
# What it deliberately skips:
#   - Caches and crash data (regenerate automatically)
#   - Electron browser state (Cookies, IndexedDB, etc. — re-login on the new machine)
#   - VM bundles + the versioned claude-code/claude-code-vm runtimes (multi-GB, rebuilt on first run)
#   - macOS Keychain credentials (you must `claude` and OAuth-login on the new machine)

set -euo pipefail

# ---------- Args ----------
TS="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-$HOME/claude-migration-$TS.tar.gz}"
DEST="$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"

# ---------- Pre-flight ----------
if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script targets macOS. On Linux/Windows the paths differ." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/claude-migration"
mkdir -p "$STAGE/home" "$STAGE/library/Claude" "$STAGE/library/Preferences"

log() { printf '[backup] %s\n' "$*"; }
copy_if_exists() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
  fi
}

# ---------- CLI: ~/.claude.json + ~/.claude/ ----------
log "Staging ~/.claude.json and ~/.claude/"
copy_if_exists "$HOME/.claude.json"        "$STAGE/home/.claude.json"
copy_if_exists "$HOME/.claudeignore"       "$STAGE/home/.claudeignore"

# rsync ~/.claude/ with excludes for cache/transient data
if [[ -d "$HOME/.claude" ]]; then
  rsync -a \
    --exclude='cache/' \
    --exclude='image-cache/' \
    --exclude='paste-cache/' \
    --exclude='shell-snapshots/' \
    --exclude='debug/' \
    --exclude='downloads/' \
    --exclude='session-env/' \
    --exclude='telemetry/' \
    --exclude='ide/' \
    --exclude='backups/' \
    --exclude='sessions/' \
    --exclude='history.jsonl' \
    --exclude='stats-cache.json' \
    --exclude='mcp-needs-auth-cache.json' \
    --exclude='security_warnings_state_*.json' \
    --exclude='.last-cleanup' \
    --exclude='.DS_Store' \
    "$HOME/.claude/" "$STAGE/home/.claude/"
fi

# ---------- Desktop: ~/Library/Application Support/Claude/ ----------
DESKTOP_SRC="$HOME/Library/Application Support/Claude"
DESKTOP_DST="$STAGE/library/Claude"

if [[ -d "$DESKTOP_SRC" ]]; then
  log "Staging Claude Desktop files (incl. Cowork sessions, MCP extensions)"
  # Whitelist: only copy known-portable items, never the Electron browser state or VMs.
  for item in \
      "claude_desktop_config.json" \
      "config.json" \
      "Preferences" \
      "window-state.json" \
      "bridge-state.json" \
      "buddy-tokens.json" \
      "cowork-enabled-cli-ops.json" \
      "extensions-installations.json" \
      "extensions-blocklist.json" \
      "ant-did" \
      "Claude Extensions" \
      "Claude Extensions Settings" \
      "claude-code-sessions" \
      "local-agent-mode-sessions"; do
    copy_if_exists "$DESKTOP_SRC/$item" "$DESKTOP_DST/$item"
  done
fi

# Secondary Claude config (Claude-3p), if present
copy_if_exists "$HOME/Library/Application Support/Claude-3p/claude_desktop_config.json" \
               "$STAGE/library/Claude-3p/claude_desktop_config.json"

# Desktop preferences plist
copy_if_exists "$HOME/Library/Preferences/com.anthropic.claudefordesktop.plist" \
               "$STAGE/library/Preferences/com.anthropic.claudefordesktop.plist"

# ---------- Shell env vars referencing Claude/Anthropic ----------
log "Capturing shell env vars (CLAUDE_* / ANTHROPIC_*)"
{
  for rc in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [[ -f "$rc" ]] || continue
    if grep -E '(CLAUDE|ANTHROPIC)' "$rc" >/dev/null 2>&1; then
      echo "## From $rc"
      grep -E '(CLAUDE|ANTHROPIC)' "$rc"
      echo
    fi
  done
} > "$STAGE/env-vars.txt"

# ---------- claude --version (informational) ----------
if command -v claude >/dev/null 2>&1; then
  claude --version > "$STAGE/claude-version.txt" 2>&1 || true
fi

# ---------- Manifest ----------
log "Writing source.env and MANIFEST.txt"
# Machine-readable source info, used by claude-restore.sh to remap paths if the
# destination user is different. Quoted so values with spaces parse cleanly when
# the restore script `source`s this file.
{
  printf 'SOURCE_HOME=%q\n'     "$HOME"
  printf 'SOURCE_USER=%q\n'     "$(basename "$HOME")"
  printf 'SOURCE_HOSTNAME=%q\n' "$(hostname)"
  printf 'SOURCE_PLATFORM=%q\n' "macOS"
} > "$STAGE/source.env"

{
  echo "Claude migration archive"
  echo "Created: $(date)"
  echo "Source host: $(hostname)"
  echo "Source user: $USER"
  echo "Source HOME: $HOME"
  echo "Source uname: $(uname -a)"
  echo
  echo "----- Contents (sizes) -----"
  ( cd "$STAGE" && du -ah . | sort -k2 )
} > "$STAGE/MANIFEST.txt"

# ---------- Tar it up ----------
log "Compressing to $DEST"
tar -czf "$DEST" -C "$WORK" claude-migration

SIZE=$(du -h "$DEST" | awk '{print $1}')
log "Done: $DEST ($SIZE)"
log "Copy this file to the new Mac and run claude-restore.sh"
