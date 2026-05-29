#!/usr/bin/env bash
# claude-backup.sh — back up Claude Code CLI + Claude Desktop (incl. Cowork) state on macOS
#
# Usage:
#   ./claude-backup.sh                                # writes ~/claude-migration-YYYYMMDD-HHMMSS.tar.gz
#   ./claude-backup.sh /path/to/output.tar.gz
#   ./claude-backup.sh --include-projects            # also bundle project working trees (filtered)
#   ./claude-backup.sh --include-projects --no-default-excludes   # bundle trees verbatim, no filters
#
# What it includes (always):
#   - Claude Code CLI: ~/.claude.json, ~/.claude/ (config, projects/auto-memory, plugins, agents,
#     skills, statusline, tasks, plans, settings, file-history)
#   - Claude Desktop: claude_desktop_config.json (MCP servers), Preferences, config.json,
#     installed Claude Extensions (MCP) and their settings, Cowork local-agent-mode sessions,
#     claude-code-sessions, window/bridge/buddy state files
#   - Shell env vars that mention CLAUDE_* / ANTHROPIC_*
#
# What it includes when --include-projects is set:
#   - Working trees of every directory referenced by ~/.claude.json `projects` keys
#     and by Cowork `spaces.json` `folders[].path` entries.
#   - By default the following are EXCLUDED (override with --no-default-excludes):
#     .git/  node_modules/  __pycache__/  .venv/  venv/  .next/  dist/  build/  target/
#     .DS_Store  .idea/  .vscode/  *.pyc
#   - Adds a `projects/.paths.txt` index to the archive so the restore script knows what to put back.
#
# What it deliberately skips:
#   - Caches and crash data (regenerate automatically)
#   - Electron browser state (Cookies, IndexedDB, etc. — re-login on the new machine)
#   - VM bundles + the versioned claude-code/claude-code-vm runtimes (multi-GB, rebuilt on first run)
#   - macOS Keychain credentials (you must `claude` and OAuth-login on the new machine)

set -euo pipefail

# ---------- Args ----------
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$HOME/claude-migration-$TS.tar.gz"
INCLUDE_PROJECTS=0
NO_DEFAULT_EXCLUDES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-projects)    INCLUDE_PROJECTS=1; shift ;;
    --no-default-excludes) NO_DEFAULT_EXCLUDES=1; shift ;;
    -h|--help)
      sed -n '2,32p' "$0"; exit 0 ;;
    *) DEST="$1"; shift ;;
  esac
done
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

# ---------- Optional: bundle project working trees ----------
PROJECTS_INCLUDED=no
if [[ $INCLUDE_PROJECTS == 1 ]]; then
  log "Discovering project paths from ~/.claude.json + Cowork spaces.json"
  # Excludes from discovery: paths that are too broad (the user's $HOME itself, or
  # direct top-level system/personal dirs we should never bulk-copy).
  # shellcheck disable=SC2016
  mapfile -t PROJECT_PATHS < <(HOME="$HOME" python3 - <<'PY' 2>/dev/null
import json, os, glob
home = os.environ['HOME']
too_broad = {
    home,
    *(os.path.join(home, d) for d in
      ('Downloads', 'Desktop', 'Documents', 'Pictures', 'Music', 'Movies',
       'Library', 'Applications', '.Trash', 'Public'))
}
paths = set()
try:
    d = json.load(open(os.path.expanduser('~/.claude.json')))
    for p in d.get('projects', {}):
        paths.add(p)
except Exception:
    pass
for f in glob.glob(os.path.expanduser('~/Library/Application Support/Claude/local-agent-mode-sessions/*/*/spaces.json')):
    try:
        d = json.load(open(f))
        for s in d.get('spaces', []):
            for fld in s.get('folders', []) or []:
                p = fld.get('path')
                if p:
                    paths.add(p)
    except Exception:
        pass
for p in sorted(paths):
    if not os.path.isdir(p):
        continue
    if p in too_broad:
        continue
    if p.startswith(('/var/', '/tmp/', '/private/var/', '/private/tmp/')):
        continue
    print(p)
PY
)
  if [[ ${#PROJECT_PATHS[@]} -eq 0 ]]; then
    log "  no project paths to bundle"
  else
    log "  found ${#PROJECT_PATHS[@]} project director(y/ies):"
    declare -a SIZES=()
    TOTAL_BYTES=0
    for p in "${PROJECT_PATHS[@]}"; do
      bytes=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
      [[ -z "$bytes" ]] && bytes=0
      human=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
      [[ -z "$human" ]] && human="?"
      SIZES+=("$human")
      TOTAL_BYTES=$((TOTAL_BYTES + bytes))
      printf '    %6s  %s\n' "$human" "$p"
    done
    TOTAL_HUMAN=$(awk -v b="$TOTAL_BYTES" 'BEGIN{
      if (b > 1048576) printf "%.1f GB", b/1048576
      else if (b > 1024) printf "%.1f MB", b/1024
      else printf "%d KB", b
    }')
    log "  total (after default excludes is roughly less): $TOTAL_HUMAN"

    if [[ $NO_DEFAULT_EXCLUDES == 0 ]]; then
      log "  default excludes ON (.git/, node_modules/, __pycache__/, .venv/, venv/, .next/, dist/, build/, target/, .idea/, .vscode/, *.pyc, .DS_Store)"
    else
      log "  default excludes OFF (--no-default-excludes)"
    fi

    if [[ -t 0 ]]; then
      read -r -p "  Proceed with bundling? [y/N] " yn
      if [[ ! "$yn" =~ ^[Yy] ]]; then
        log "  project bundling cancelled by user"
        exit 0
      fi
    else
      log "  no TTY for confirmation; proceeding (use --skip-projects on restore to undo)"
    fi

    EXCLUDE_FLAGS=()
    if [[ $NO_DEFAULT_EXCLUDES == 0 ]]; then
      for ex in '.git/' 'node_modules/' '__pycache__/' '.venv/' 'venv/' \
                '.next/' 'dist/' 'build/' 'target/' '.idea/' '.vscode/' \
                '.DS_Store' '*.pyc'; do
        EXCLUDE_FLAGS+=(--exclude="$ex")
      done
    fi

    PROJECTS_STAGE="$STAGE/projects"
    mkdir -p "$PROJECTS_STAGE"
    : > "$PROJECTS_STAGE/.paths.txt"
    for p in "${PROJECT_PATHS[@]}"; do
      rel="${p#/}"
      dst="$PROJECTS_STAGE/$rel"
      mkdir -p "$dst"
      log "  bundling $p"
      rsync -a "${EXCLUDE_FLAGS[@]}" "$p/" "$dst/"
      printf '%s\n' "$p" >> "$PROJECTS_STAGE/.paths.txt"
    done
    PROJECTS_INCLUDED=yes

    SZ=$(du -sh "$PROJECTS_STAGE" 2>/dev/null | awk '{print $1}')
    log "  total bundled project size after excludes: $SZ"
  fi
fi

# ---------- Manifest ----------
log "Writing source.env and MANIFEST.txt"
# Machine-readable source info, used by claude-restore.sh to remap paths if the
# destination user is different. Quoted so values with spaces parse cleanly when
# the restore script `source`s this file.
{
  printf 'SOURCE_HOME=%q\n'        "$HOME"
  printf 'SOURCE_USER=%q\n'        "$(basename "$HOME")"
  printf 'SOURCE_HOSTNAME=%q\n'    "$(hostname)"
  printf 'SOURCE_PLATFORM=%q\n'    "macOS"
  printf 'PROJECTS_INCLUDED=%q\n'  "$PROJECTS_INCLUDED"
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
