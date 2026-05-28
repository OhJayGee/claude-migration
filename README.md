# Claude migration scripts

Move Claude Code (CLI + UI) and Claude Desktop (incl. Cowork) state from one machine to another.

**Version:** v0.1.0 — MIT-licensed.

Two parallel implementations are provided:

| Platform | Backup | Restore |
| --- | --- | --- |
| macOS (bash) | `claude-backup.sh` | `claude-restore.sh` |
| Windows (PowerShell) | `claude-backup.ps1` | `claude-restore.ps1` |

## Test status

| What | Status |
| --- | --- |
| macOS backup → archive integrity → dry-run restore → username remap (simulated against a fake `$HOME`) | **Tested** on macOS 15 (Darwin 25.5.0, arm64) against Claude Code CLI 2.1.153 + Claude Desktop with Cowork enabled. |
| macOS full restore over a real install (move-aside → overwrite → relaunch Claude.app) | **Not runtime-tested.** The logic is straightforward but exercising it would require clobbering a live install or using a separate test account / VM. |
| Windows backup, restore, and remap | **Not runtime-tested.** Direct port of the macOS logic, syntax-reviewed only. PowerShell isn't on the author's machine. Run with `-DryRun` first. |
| Cross-platform (Mac↔Windows) restore | **Not supported.** Both restore scripts detect and refuse a foreign-platform archive. |
| Linux | **Not addressed.** Claude Code CLI runs on Linux but Claude Desktop / Cowork does not, so a separate Linux backup script would only cover `~/.claude*`. PRs welcome. |

Treat this as a v0.1 of a community tool, not a battle-tested utility.

Cross-platform migrations (Mac→Windows or Windows→Mac) are **not** supported by these scripts: the encoded project-directory format is platform-specific (`/Users/olv` becomes `-Users-olv-` on macOS, but `C:\Users\olv` becomes `-C--Users-olv-` on Windows). The restore script will detect a cross-platform archive and refuse to run.

## TL;DR (macOS)

```bash
# On the old Mac
./claude-backup.sh                # writes ~/claude-migration-YYYYMMDD-HHMMSS.tar.gz

# Move the archive across (AirDrop / scp / USB).

# On the new Mac (after installing Claude.app and the Claude Code CLI)
./claude-restore.sh ~/claude-migration-*.tar.gz --dry-run
./claude-restore.sh ~/claude-migration-*.tar.gz
```

Then on the new Mac: run `claude` once to re-authenticate, and launch Claude.app and sign in.

## TL;DR (Windows)

**Do I need to install anything?** No. Windows PowerShell 5.1 ships with Windows 10 and 11. To open it, press **Win+X** and pick **"Terminal"** (Windows 11) or **"Windows PowerShell"** (Windows 10), or type `powershell` in the Start menu. The scripts use only cmdlets that exist in stock 5.1 (`Compress-Archive`, `Expand-Archive`, `Copy-Item`, etc.), so PowerShell 7 / `pwsh` is not required.

```powershell
# On the old PC
.\claude-backup.ps1                # writes %USERPROFILE%\claude-migration-<ts>.zip

# Move the .zip across (OneDrive / USB / scp).

# On the new PC (after installing Claude Desktop and the Claude Code CLI)
.\claude-restore.ps1 -Archive C:\path\claude-migration-*.zip -DryRun
.\claude-restore.ps1 -Archive C:\path\claude-migration-*.zip
```

Then on the new PC: run `claude` once to re-authenticate, and launch Claude Desktop and sign in.

### If PowerShell refuses to run the script

By default Windows blocks unsigned `.ps1` files. Two ways around it — neither requires admin rights and neither changes anything permanently:

**A. Allow scripts for the current PowerShell window only:**

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\claude-restore.ps1 -Archive C:\path\to\claude-migration.zip -DryRun
```

`-Scope Process` only affects the PowerShell window you're in. Close it and the default policy is back.

**B. Invoke without changing policy at all** (works from `cmd.exe`, the Run dialog, or PowerShell):

```cmd
powershell -ExecutionPolicy Bypass -File .\claude-restore.ps1 -Archive C:\path\to\claude-migration.zip -DryRun
```

## Why a script and not an official Anthropic flow

There is no official Anthropic-blessed migration tool. The only first-party migration documentation is the **chat-memory** import/export at <https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude> — that covers the cross-conversation memory in Claude.app / claude.ai (server-side, per account) but **not** local files, MCP config, plugins, projects, Cowork sessions, or anything in `~/.claude/`.

This script bundles all those local pieces.

## What gets copied

Paths use macOS notation. Windows equivalents:

| macOS | Windows |
| --- | --- |
| `~/.claude.json` | `%USERPROFILE%\.claude.json` |
| `~/.claude/` | `%USERPROFILE%\.claude\` |
| `~/Library/Application Support/Claude/` | `%APPDATA%\Claude\` |
| `~/Library/Preferences/com.anthropic.claudefordesktop.plist` | not used on Windows (Electron prefs live inside `%APPDATA%\Claude\`) |

### Claude Code (CLI)
- `~/.claude.json` — user ID, MCP server registrations, per-project trust state, onboarding flags
- `~/.claude/settings.json`, `settings.local.json`
- `~/.claude/projects/` — **auto memory + recorded sessions per project** (typically the largest item)
- `~/.claude/plugins/` — installed plugins, marketplaces, plugin data
- `~/.claude/agents/`, `skills/`, `tasks/`, `plans/`, `statusline/`, `config/`, `file-history/`

### Claude Desktop (incl. Cowork)
- `claude_desktop_config.json` — MCP servers + Desktop preferences (Cowork toggles, paired browser id, trusted folders…)
- `Preferences`, `config.json`, `window-state.json`, `bridge-state.json`, `buddy-tokens.json`, `cowork-enabled-cli-ops.json`, `extensions-installations.json`, `extensions-blocklist.json`
- `Claude Extensions/` + `Claude Extensions Settings/` — installed MCP extensions (e.g. filesystem, chrome-control, third-party `.mcpb` extensions) and their per-extension config
- `claude-code-sessions/` — Claude Code panels opened from inside the app
- `local-agent-mode-sessions/` — **Cowork chat sessions**
- macOS only: `~/Library/Preferences/com.anthropic.claudefordesktop.plist`, `~/Library/Application Support/Claude-3p/` (secondary install)

### Shell environment
The script captures any line in `~/.zshrc`/`~/.zshenv`/`~/.zprofile`/`~/.bashrc`/`~/.bash_profile` that mentions `CLAUDE` or `ANTHROPIC` into `env-vars.txt`. The restore script **prints** these for you to paste into the new machine's shell rc — it never edits your shell profile directly.

## What gets skipped (and why)

- **Caches**: `Cache/`, `Code Cache/`, `GPUCache/`, `Dawn*Cache/`, `~/.claude/cache`, `image-cache`, `paste-cache`, `shell-snapshots`, `~/Library/Caches/claude-*`. Regenerate automatically.
- **Local VM images**: `vm_bundles/` (often 5-10 GB), `claude-code-vm/`, `claude-code/` (versioned runtime caches). Recreated on first launch.
- **Electron browser state**: `Cookies*`, `IndexedDB/`, `Local Storage/`, `Session Storage/`, `Trust Tokens*`, `TransportSecurity`, etc. You'll re-login on the new machine anyway.
- **Crash/telemetry**: `Crashpad/`, `sentry/`, `~/Library/Logs/Claude/`, `~/.claude/telemetry`, `~/.claude/debug`, `security_warnings_state_*.json`.
- **Auth credentials**: Anthropic OAuth tokens live in the **macOS Keychain**, not in any of these files. They do not transfer through the archive. After restore, run `claude` once and complete the OAuth flow; launch Claude.app and sign in.
- **The `claude` binary itself**: install separately via `curl -fsSL https://claude.ai/install.sh | bash` (or whatever method your friend uses).

## What does NOT transfer via this script

1. **Chat memory** in Claude.app / claude.ai (the cross-conversation memory feature). Move it with the official import/export: <https://support.claude.com/en/articles/12123587>.
2. **Anthropic API keys** in your shell rc — those are captured into `env-vars.txt` but you must paste them into the new machine's shell rc yourself.
3. **GitHub / cloud / MCP tokens** kept in environment variables — same as above.
4. **macOS Keychain entries** — re-authenticate on the new machine.
5. **Per-repo `.claude/` directories**, `CLAUDE.md`, `.mcp.json`, `CLAUDE.local.md` inside each project. Those live alongside your code; move them with your normal repo workflow (git pull / clone / rsync of source trees).
6. **Source code your projects refer to** (e.g. `/Users/you/SRC/foo/`). The migration only carries Claude's metadata about these projects (paths, trust state, per-project auto-memory, session transcripts). Move the working trees themselves with git or rsync, exactly as you would for any code.

## What each Claude surface stores, and what we capture

| Surface | Where it lives | Captured? | Notes |
| --- | --- | --- | --- |
| **claude.ai / Claude.app chats** (sidebar "chat" mode) | Server-side, per Anthropic account | n/a — re-login on the new Mac and they reappear | Claude.app and claude.ai are two clients of the same backend; chats are identical across them. Nothing on disk is needed to "transfer" them. |
| **Claude.app chat memory** | Server-side, per account | Not via this script | Use the Settings → Capabilities → Memory export/import flow. |
| **Claude Code CLI sessions** | `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` | Yes | All projects + transcripts. |
| **Claude Code panel inside Claude.app** | Metadata in `~/Library/Application Support/Claude/claude-code-sessions/`; transcripts share `~/.claude/projects/` with the CLI | Yes | The panel uses the bundled `claude` binary under the hood and writes to the same projects store as the CLI. |
| **Cowork** (Local Agent Mode) — transcripts, audit logs, plans, per-session outputs/uploads, MCP perms | `~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<device>/local_<uuid>/` | Yes | Each session has its own `audit.jsonl`, `outputs/`, `uploads/`, and a private `.claude/projects/` jsonl. |
| **Cowork** — the sandbox VM's *internal* filesystem | `~/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img` (10 GB) + `sessiondata.img` (1.4 GB) | **No** | This is an Apple Virtualization framework disk image, not session-scoped. We skip it to keep the archive small and because the new Mac will provision a fresh VM. If Cowork sessions contained in-progress work that only lives inside the VM (not yet downloaded to host as outputs), grab those files via Cowork's download UI before you migrate. |
| **MCP servers (CLI)** | `~/.claude.json` (`mcpServers` key) + `.mcp.json` per repo | Yes for CLI scope; per-repo lives with your code | |
| **MCP servers (Desktop) / Extensions** | `~/Library/Application Support/Claude/claude_desktop_config.json` + `Claude Extensions/` + `Claude Extensions Settings/` | Yes | Includes installed `.mcpb` extensions and their per-extension settings. |
| **Plugins** | `~/.claude/plugins/` | Yes | |
| **Auto memory** | `~/.claude/projects/<encoded-cwd>/memory/MEMORY.md` and topic files | Yes | |
| **User-level `CLAUDE.md` / rules** | `~/.claude/CLAUDE.md`, `~/.claude/rules/` | Yes | |
| **OAuth tokens** | macOS Keychain | No | Re-login on the new Mac. |
| **Caches, VM bundles, Electron browser state** | Various | No | Regenerate automatically. |

## Different username on the new Mac

The backup tarball includes a `source.env` file that records the source `$HOME` and username. When you run `claude-restore.sh`, it compares the source username with the destination's `$HOME` and, if they differ, prompts to rewrite paths automatically.

What gets rewritten:

- `~/.claude.json` — the `projects` keys (`/Users/olduser/SRC/foo` → `/Users/newuser/SRC/foo`) and any other absolute-path references.
- `~/.claude/projects/-Users-olduser-…/` directory names — renamed in place to `-Users-newuser-…`.
- `.json`, `.jsonl`, `.md`, `.txt` files under `~/.claude/`, `claude-code-sessions/`, `local-agent-mode-sessions/`, and `Claude Extensions Settings/` — every `/Users/olduser/` and `-Users-olduser-` is rewritten.
- The Claude Desktop preferences plist (binary plists are converted to XML first so sed can touch them).
- `claude_desktop_config.json` and `config.json` — including the `localAgentModeTrustedFolders` Cowork pref and any MCP-server `env` paths.

Override flags:

- `--remap-to=USER` — force a different target username (otherwise `$(basename "$HOME")`).
- `--no-remap` — leave all paths as the source's. Claude Code tolerates stale project keys, but Cowork's trusted folders and the filesystem extension's `allowed_directories` won't work until you fix them by hand.

What we deliberately do NOT rewrite:

- `~/.claude/file-history/*` — content-hashed snapshots of files Claude has edited. The hash filenames depend on the original content, so rewriting them would invalidate the lookup. References to the old `/Users/olduser/` path inside these snapshots are historical metadata, not active config.
- `audit.jsonl` transcripts inside `local-agent-mode-sessions/.../local_<uuid>/` — these are immutable records of past Cowork conversations (with HMACs). Rewriting them would invalidate the HMAC and isn't useful: it's history, not state.
- Anything that doesn't end in `.json`, `.jsonl`, `.md`, or `.txt` — to keep the remap safe.

## Safety

`claude-restore.sh`:
- Refuses to run if the archive isn't a valid claude-migration bundle.
- Quits `Claude.app` first (it writes config on exit and would clobber the restore).
- Moves any pre-existing `~/.claude`, `~/.claude.json`, and overwritten Desktop items into a timestamped `~/claude-pre-restore-YYYYMMDD-HHMMSS/` before writing.
- Supports `--dry-run` to print what *would* happen.

## Tested

Backup script was tested on the source machine; archive integrity verified with `tar -tzf` and the resulting MANIFEST.txt. Restore is intentionally idempotent and reversible (via the move-aside directory).

## Sources

This script was designed by combining Anthropic's official Claude Code documentation, the official Claude.ai memory import/export support article, observations from inspecting an actual Claude Code + Claude Desktop install on macOS, and a few community references.

**Anthropic (official):**
- [Claude Code — Settings](https://code.claude.com/docs/en/settings) — file/directory hierarchy for `~/.claude/`, `~/.claude.json`, `.claude/`, settings layers, plugin/skill locations.
- [Claude Code — Memory](https://code.claude.com/docs/en/memory) — `CLAUDE.md` resolution order, auto memory directory at `~/.claude/projects/<project>/memory/`, scoping rules.
- [Claude Code — Hooks Guide](https://code.claude.com/docs/en/hooks-guide) (referenced for completeness on what config carries hooks).
- [Anthropic Support — Import and export your memory from Claude](https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude) — the only first-party memory-migration flow, scoped to the cross-conversation memory feature in Claude.app / claude.ai (server-side, per account).
- [GitHub issue: Session Export/Import for Cross-Machine Portability (anthropics/claude-code#18645)](https://github.com/anthropics/claude-code/issues/18645) — confirms there is no official cross-machine session/config migration tool.

**Community references reviewed for prior art (used as cross-checks, not copied):**
- [DRVBSS/cowork-migrate](https://github.com/DRVBSS/cowork-migrate) — narrower scope, Mac-to-Mac migration of Cowork (Local Agent Mode) sessions only.
- [jtklinger/claude-code-backup-guide](https://github.com/jtklinger/claude-code-backup-guide) — community write-up on backing up Claude Code state.
- [dirkstrauss.com — Claude Code Windows Migration Guide](https://dirkstrauss.com/claude-code-windows-migration-guide/) — Windows-equivalent of the same exercise.
- [gist: Claude Code `--continue` after directory `mv`](https://gist.github.com/gwpl/e0b78a711b4a6b2fc4b594c9b9fa2c4c) — explains how absolute paths in `~/.claude.json` and `~/.claude/projects/<encoded-cwd>/` interact when paths change.

**Direct inspection of an installed Claude environment** (used to validate which paths actually exist and what they store):
- `~/.claude/` and `~/.claude.json` on the source Mac.
- `~/Library/Application Support/Claude/` (Claude.app), including `claude_desktop_config.json`, `Claude Extensions/`, `Claude Extensions Settings/`, `claude-code-sessions/`, `local-agent-mode-sessions/`, `vm_bundles/`, `claude-code/`, `claude-code-vm/`.
- `~/Library/Preferences/com.anthropic.claudefordesktop.plist`.
- `~/Library/Caches/claude-cli-nodejs`, `~/Library/Logs/Claude/` (skipped — caches and logs).
- Reading the `cwd` field inside `claude-code-sessions/*.json` confirmed the Desktop "Claude Code" panels reuse the same `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` store as the standalone CLI.
