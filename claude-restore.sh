#!/usr/bin/env bash
# claude-restore.sh — restore an archive built by claude-backup.sh on a new macOS machine.
#
# Usage:
#   ./claude-restore.sh path/to/claude-migration-YYYYMMDD-HHMMSS.tar.gz [--dry-run]
#
# Behavior:
#   - Quits Claude.app first (it caches state on disk and will overwrite restored files on exit).
#   - Backs up any existing ~/.claude, ~/.claude.json, and Desktop config into ~/claude-pre-restore-<ts>/
#     before overwriting.
#   - Restores all files captured by claude-backup.sh to their original locations.
#   - Prints the env-vars list and post-restore steps (re-login + import web-memory) at the end.

set -euo pipefail

ARCHIVE=""
DRY_RUN=0
REMAP_USER=""        # explicit target username; empty = derive from $HOME
NO_REMAP=0           # if set, skip path remapping even when usernames differ
SKIP_PROJECTS=0      # if set, don't restore bundled project working trees

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --no-remap)       NO_REMAP=1; shift ;;
    --skip-projects)  SKIP_PROJECTS=1; shift ;;
    --remap-to=*)     REMAP_USER="${1#*=}"; shift ;;
    --remap-to)       REMAP_USER="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 <archive.tar.gz> [--dry-run] [--no-remap] [--remap-to=USER] [--skip-projects]

  --dry-run         Show what would be restored and remapped, write nothing.
  --no-remap        Don't rewrite any paths even if source and destination
                    usernames differ.
  --remap-to USER   Force the destination username (otherwise auto-detected
                    from \$HOME).
  --skip-projects   Don't restore bundled project working trees even if the
                    archive contains them.
EOF
      exit 0
      ;;
    *)
      if [[ -z "$ARCHIVE" ]]; then ARCHIVE="$1"; shift
      else echo "Unknown arg: $1" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "Usage: $0 <archive.tar.gz> [--dry-run] [--no-remap] [--remap-to=USER]" >&2
  exit 1
fi
if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script targets macOS." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[restore] Extracting $ARCHIVE -> $WORK"
tar -xzf "$ARCHIVE" -C "$WORK"
STAGE="$WORK/claude-migration"
[[ -d "$STAGE" ]] || { echo "Archive does not contain claude-migration/ — wrong file?" >&2; exit 1; }

echo
echo "[restore] Archive manifest (top 30 lines):"
head -30 "$STAGE/MANIFEST.txt" 2>/dev/null || true
echo

# ---------- Detect source vs. destination user ----------
SOURCE_HOME=""
SOURCE_USER=""
SOURCE_PLATFORM=""
if [[ -f "$STAGE/source.env" ]]; then
  # shellcheck disable=SC1091
  source "$STAGE/source.env"
fi

# Refuse cross-platform restore. The encoded project-directory format differs
# (-Users-olv- on macOS vs -C--Users-olv- on Windows) and other layout details
# diverge — a separate cross-platform migrator would be needed.
if [[ -n "$SOURCE_PLATFORM" && "$SOURCE_PLATFORM" != "macOS" ]]; then
  echo "[restore] Archive was created on $SOURCE_PLATFORM, not macOS." >&2
  echo "[restore] Cross-platform restore is not supported. Aborting." >&2
  exit 2
fi
DEST_HOME="$HOME"
DEST_USER="$(basename "$HOME")"
[[ -n "$REMAP_USER" ]] && DEST_USER="$REMAP_USER" && DEST_HOME="/Users/$REMAP_USER"

NEED_REMAP=0
if [[ -n "$SOURCE_HOME" && "$SOURCE_HOME" != "$DEST_HOME" ]]; then
  NEED_REMAP=1
fi

echo "[restore] Source: HOME=$SOURCE_HOME  user=$SOURCE_USER"
echo "[restore] This:   HOME=$DEST_HOME  user=$DEST_USER"
if (( NEED_REMAP )); then
  if (( NO_REMAP )); then
    echo "[restore] Usernames differ but --no-remap given — paths will NOT be rewritten."
  else
    echo "[restore] Usernames differ — paths will be rewritten after restore."
  fi
else
  echo "[restore] Usernames match — no path remap needed."
fi
echo

if (( DRY_RUN )); then
  echo "[restore] DRY-RUN — would restore the following paths under $HOME:"
  ( cd "$STAGE/home" 2>/dev/null && find . -maxdepth 2 -mindepth 1 ) | sed 's|^\./|  ~/|'
  if [[ -d "$STAGE/library/Claude" ]]; then
    ( cd "$STAGE/library/Claude" && find . -maxdepth 1 -mindepth 1 ) \
      | sed "s|^\./|  ~/Library/Application Support/Claude/|"
  fi
  if [[ -d "$STAGE/library/Preferences" ]]; then
    ( cd "$STAGE/library/Preferences" && find . -maxdepth 1 -mindepth 1 ) \
      | sed "s|^\./|  ~/Library/Preferences/|"
  fi
  if (( NEED_REMAP )) && (( ! NO_REMAP )); then
    echo
    echo "[restore] DRY-RUN — would then rewrite paths:"
    echo "    /Users/$SOURCE_USER/  ->  /Users/$DEST_USER/"
    echo "    -Users-$SOURCE_USER-  ->  -Users-$DEST_USER-"
    echo "  in JSON/JSONL/MD/TXT files under ~/.claude, claude-code-sessions,"
    echo "  local-agent-mode-sessions, and the desktop plist; project directory"
    echo "  names under ~/.claude/projects/ will be renamed accordingly."
  fi
  if [[ -d "$STAGE/projects" && -f "$STAGE/projects/.paths.txt" && $SKIP_PROJECTS == 0 ]]; then
    echo
    COUNT=$(wc -l < "$STAGE/projects/.paths.txt" | tr -d ' ')
    PROJ_SIZE=$(du -sh "$STAGE/projects" 2>/dev/null | awk '{print $1}')
    echo "[restore] DRY-RUN — archive includes $COUNT project director(y/ies), total $PROJ_SIZE."
    echo "[restore] DRY-RUN — would restore (after username remap):"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if (( NEED_REMAP )) && (( ! NO_REMAP )); then
        echo "    ${p//\/Users\/$SOURCE_USER\//\/Users\/$DEST_USER\/}"
      else
        echo "    $p"
      fi
    done < "$STAGE/projects/.paths.txt"
  fi
  exit 0
fi

# ---------- Confirmation ----------
echo "[restore] This will overwrite existing Claude config on this Mac."
echo "[restore] Anything currently at the target paths will first be moved to:"
PRE="$HOME/claude-pre-restore-$(date +%Y%m%d-%H%M%S)"
echo "          $PRE"
echo
read -r -p "Continue? [y/N] " yn
[[ "$yn" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
mkdir -p "$PRE"

# ---------- Quit Claude.app if running ----------
if pgrep -x "Claude" >/dev/null 2>&1; then
  echo "[restore] Quitting Claude.app to prevent it from overwriting restored files"
  osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1 || true
  sleep 2
fi

# ---------- Move-aside existing ----------
move_aside() {
  local p="$1"
  if [[ -e "$p" ]]; then
    local rel="${p#"$HOME"/}"
    mkdir -p "$PRE/$(dirname "$rel")"
    mv "$p" "$PRE/$rel"
    echo "[restore]   moved aside: $p"
  fi
}
move_aside "$HOME/.claude"
move_aside "$HOME/.claude.json"
move_aside "$HOME/.claudeignore"
# Desktop: we whitelist-overwrite individual items rather than nuking the whole Application Support
# dir, since that dir also contains caches/VMs that we don't want to lose.

# ---------- Restore HOME ----------
echo "[restore] Restoring ~/.claude.json and ~/.claude/"
if [[ -d "$STAGE/home" ]]; then
  rsync -a "$STAGE/home/" "$HOME/"
fi

# ---------- Restore Claude Desktop ----------
DESKTOP_DST="$HOME/Library/Application Support/Claude"
mkdir -p "$DESKTOP_DST"
if [[ -d "$STAGE/library/Claude" ]]; then
  echo "[restore] Restoring Claude Desktop files into $DESKTOP_DST"
  for item in "$STAGE/library/Claude/"*; do
    [[ -e "$item" ]] || continue
    name="$(basename "$item")"
    target="$DESKTOP_DST/$name"
    move_aside "$target"
    cp -R "$item" "$DESKTOP_DST/"
    echo "[restore]   restored: $target"
  done
fi

# Claude-3p (secondary Claude install), if archived
if [[ -d "$STAGE/library/Claude-3p" ]]; then
  mkdir -p "$HOME/Library/Application Support/Claude-3p"
  cp -R "$STAGE/library/Claude-3p/." "$HOME/Library/Application Support/Claude-3p/"
fi

# Preferences plist
if [[ -f "$STAGE/library/Preferences/com.anthropic.claudefordesktop.plist" ]]; then
  cp "$STAGE/library/Preferences/com.anthropic.claudefordesktop.plist" \
     "$HOME/Library/Preferences/com.anthropic.claudefordesktop.plist"
fi

# ---------- Path remap (if usernames differ) ----------
remap_paths() {
  local src_user="$1" dst_user="$2"
  local src_home="/Users/$src_user" dst_home="/Users/$dst_user"

  echo "[remap] Rewriting absolute paths: $src_home -> $dst_home"
  echo "[remap] Rewriting encoded paths : -Users-$src_user- -> -Users-$dst_user-"

  # 1. Rename ~/.claude/projects/-Users-<src_user>-... directories.
  if [[ -d "$HOME/.claude/projects" ]]; then
    local prefix_old="-Users-$src_user-" prefix_new="-Users-$dst_user-"
    find "$HOME/.claude/projects" -maxdepth 1 -mindepth 1 -type d \
         -name "${prefix_old}*" -print0 \
      | while IFS= read -r -d '' old; do
          local base new
          base="$(basename "$old")"
          new="$HOME/.claude/projects/${prefix_new}${base#"$prefix_old"}"
          echo "[remap]   mv $base  ->  $(basename "$new")"
          mv "$old" "$new"
        done
  fi

  # 2. In-place string replace inside known text files (JSON, JSONL, MD, TXT).
  #    The replacement patterns include leading/trailing slashes/hyphens to
  #    avoid matching usernames as bare substrings.
  local sed_args=(
    -e "s|/Users/${src_user}/|/Users/${dst_user}/|g"
    -e "s|-Users-${src_user}-|-Users-${dst_user}-|g"
  )

  local roots=(
    "$HOME/.claude.json"
    "$HOME/.claude"
    "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    "$HOME/Library/Application Support/Claude/config.json"
    "$HOME/Library/Application Support/Claude/Claude Extensions Settings"
    "$HOME/Library/Application Support/Claude/claude-code-sessions"
    "$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
  )

  for root in "${roots[@]}"; do
    [[ -e "$root" ]] || continue
    if [[ -f "$root" ]]; then
      sed -i '' "${sed_args[@]}" "$root" 2>/dev/null || true
    else
      find "$root" -type f \
        \( -name '*.json' -o -name '*.jsonl' -o -name '*.md' -o -name '*.txt' \) \
        -print0 \
      | xargs -0 -I{} sed -i '' "${sed_args[@]}" "{}" 2>/dev/null || true
    fi
  done

  # 3. The Desktop preferences plist may be in binary format; normalize to XML
  #    first so sed can read it, then rewrite. macOS reads either format.
  local plist="$HOME/Library/Preferences/com.anthropic.claudefordesktop.plist"
  if [[ -f "$plist" ]]; then
    plutil -convert xml1 "$plist" 2>/dev/null || true
    sed -i '' "${sed_args[@]}" "$plist" 2>/dev/null || true
  fi

  echo "[remap] Done."
}

if (( NEED_REMAP )) && (( ! NO_REMAP )); then
  echo
  read -r -p "[remap] Rewrite paths from /Users/$SOURCE_USER/ to /Users/$DEST_USER/? [Y/n] " yn
  if [[ -z "$yn" || "$yn" =~ ^[Yy] ]]; then
    remap_paths "$SOURCE_USER" "$DEST_USER"
  else
    echo "[remap] Skipped."
  fi
fi

# ---------- Optional: restore bundled project working trees ----------
if [[ -d "$STAGE/projects" && -f "$STAGE/projects/.paths.txt" && $SKIP_PROJECTS == 0 ]]; then
  echo
  COUNT=$(wc -l < "$STAGE/projects/.paths.txt" | tr -d ' ')
  PROJ_SIZE=$(du -sh "$STAGE/projects" 2>/dev/null | awk '{print $1}')
  echo "[restore] Archive includes $COUNT project director(y/ies), total $PROJ_SIZE."
  echo "[restore] Each will be restored to its original path (with username remap if needed)."
  echo "[restore] Existing directories at those paths will be moved aside to $PRE/projects/."
  read -r -p "Restore project trees now? [Y/n] " yn
  if [[ -z "$yn" || "$yn" =~ ^[Yy] ]]; then
    while IFS= read -r src_path; do
      [[ -n "$src_path" ]] || continue
      stage_path="$STAGE/projects${src_path}"
      [[ -d "$stage_path" ]] || { echo "[restore]   missing in archive, skipping: $src_path"; continue; }

      if (( NEED_REMAP )) && (( ! NO_REMAP )); then
        dst_path="${src_path//\/Users\/$SOURCE_USER\//\/Users\/$DEST_USER\/}"
      else
        dst_path="$src_path"
      fi

      if [[ -e "$dst_path" ]]; then
        BACKUP_NAME="$PRE/projects$dst_path"
        mkdir -p "$(dirname "$BACKUP_NAME")"
        mv "$dst_path" "$BACKUP_NAME"
        echo "[restore]   moved aside existing: $dst_path"
      fi
      mkdir -p "$dst_path"
      rsync -a "$stage_path/" "$dst_path/"
      echo "[restore]   restored: $dst_path"
    done < "$STAGE/projects/.paths.txt"
  else
    echo "[restore] Project tree restore skipped."
  fi
fi

# ---------- Post-restore notes ----------
echo
echo "[restore] Restore complete."
echo
echo "Pre-restore backup of any overwritten files: $PRE"
echo
echo "Next steps on this machine:"
echo "  1. Re-authenticate Claude Code:    claude   (then go through OAuth login in the browser)"
echo "  2. Verify CLI MCP servers:         claude mcp list"
echo "  3. Launch Claude.app and sign in.  MCP extensions and Cowork sessions should appear."
echo "  4. Reinstall the Claude Code CLI if needed (this script does not install the binary):"
echo "       curl -fsSL https://claude.ai/install.sh | bash"
echo
if [[ -s "$STAGE/env-vars.txt" ]]; then
  echo "Shell env vars detected on the source machine — add them to ~/.zshrc on this one if you still want them:"
  echo "----"
  cat "$STAGE/env-vars.txt"
  echo "----"
fi
echo
echo "Web/desktop chat 'Memory' (the cross-conversation memory in claude.ai and the Claude app) is"
echo "stored server-side per account and does NOT transfer through filesystem migration. To move it,"
echo "use the official export/import flow:"
echo "  https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude"
