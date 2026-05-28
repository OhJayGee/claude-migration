# claude-backup.ps1 — back up Claude Code CLI + Claude Desktop (incl. Cowork) state on Windows.
#
# Usage (PowerShell):
#   .\claude-backup.ps1                            # writes %USERPROFILE%\claude-migration-<timestamp>.zip
#   .\claude-backup.ps1 -OutputPath C:\path\out.zip
#
# What it captures (Windows paths):
#   - Claude Code CLI: %USERPROFILE%\.claude.json, %USERPROFILE%\.claude\
#     (settings, projects/auto-memory, plugins, agents, skills, statusline, tasks, plans,
#      file-history, config)
#   - Claude Desktop: %APPDATA%\Claude\ (claude_desktop_config.json, config.json,
#     Preferences, window-state.json, bridge-state.json, buddy-tokens.json,
#     cowork-enabled-cli-ops.json, extensions-installations.json, extensions-blocklist.json,
#     Claude Extensions\, Claude Extensions Settings\, claude-code-sessions\,
#     local-agent-mode-sessions\)
#   - User env vars referencing CLAUDE_* / ANTHROPIC_*
#
# What it deliberately skips:
#   - Caches and crash data (regenerate)
#   - Electron browser state (Cookies, IndexedDB, etc. — re-login on the new PC)
#   - VM bundles / WSL images (multi-GB, machine-local)
#   - Windows Credential Manager entries (where OAuth tokens live — re-login on the new PC)

[CmdletBinding()]
param(
  [string] $OutputPath = (Join-Path $env:USERPROFILE ("claude-migration-{0}.zip" -f (Get-Date -Format "yyyyMMdd-HHmmss")))
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne "Win32NT") {
  Write-Error "This script is for Windows. On macOS use claude-backup.sh."
}

function Log { param([string]$Msg) Write-Host "[backup] $Msg" }

# Staging directory
$Work  = Join-Path $env:TEMP ("claude-migration-{0}" -f ([System.Guid]::NewGuid().ToString("N")))
$Stage = Join-Path $Work "claude-migration"
New-Item -ItemType Directory -Path $Stage             | Out-Null
New-Item -ItemType Directory -Path "$Stage\home"      | Out-Null
New-Item -ItemType Directory -Path "$Stage\appdata"   | Out-Null

try {
  $UserProfile = $env:USERPROFILE
  $AppData     = $env:APPDATA

  # ---------- CLI: ~/.claude.json + ~/.claude/ ----------
  Log "Staging .claude.json and .claude\"
  if (Test-Path "$UserProfile\.claude.json")  { Copy-Item "$UserProfile\.claude.json" "$Stage\home\.claude.json" }
  if (Test-Path "$UserProfile\.claudeignore") { Copy-Item "$UserProfile\.claudeignore" "$Stage\home\.claudeignore" }

  if (Test-Path "$UserProfile\.claude") {
    $skipNames = @(
      "cache", "image-cache", "paste-cache", "shell-snapshots", "debug",
      "downloads", "session-env", "telemetry", "ide", "backups", "sessions"
    )
    $skipFiles = @(
      "history.jsonl", "stats-cache.json", "mcp-needs-auth-cache.json", ".last-cleanup"
    )
    $dstClaude = "$Stage\home\.claude"
    New-Item -ItemType Directory -Path $dstClaude -Force | Out-Null
    Get-ChildItem -Force -Path "$UserProfile\.claude" | ForEach-Object {
      if ($skipNames -contains $_.Name) { return }
      if ($skipFiles -contains $_.Name) { return }
      if ($_.Name -like "security_warnings_state_*.json") { return }
      Copy-Item -Recurse -Force $_.FullName -Destination $dstClaude
    }
  }

  # ---------- Desktop: %APPDATA%\Claude\ ----------
  $DesktopSrc = Join-Path $AppData "Claude"
  $DesktopDst = "$Stage\appdata\Claude"
  if (Test-Path $DesktopSrc) {
    Log "Staging Claude Desktop files (incl. Cowork sessions, MCP extensions)"
    New-Item -ItemType Directory -Path $DesktopDst -Force | Out-Null
    # Whitelist of portable items only — never the Electron browser state or VM caches.
    $items = @(
      "claude_desktop_config.json", "config.json", "Preferences",
      "window-state.json", "bridge-state.json", "buddy-tokens.json",
      "cowork-enabled-cli-ops.json", "extensions-installations.json",
      "extensions-blocklist.json", "ant-did",
      "Claude Extensions", "Claude Extensions Settings",
      "claude-code-sessions", "local-agent-mode-sessions"
    )
    foreach ($it in $items) {
      $src = Join-Path $DesktopSrc $it
      if (Test-Path $src) { Copy-Item -Recurse -Force $src -Destination $DesktopDst }
    }
  }

  # ---------- Environment variables ----------
  Log "Capturing user env vars (CLAUDE_* / ANTHROPIC_*)"
  $envLines = @()
  foreach ($scope in @("User", "Process")) {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in $vars.Keys) {
      if ($k -match "^(CLAUDE|ANTHROPIC)") {
        $envLines += ("## scope={0}" -f $scope)
        $envLines += ("{0}={1}" -f $k, $vars[$k])
      }
    }
  }
  $envLines -join "`n" | Set-Content -Path "$Stage\env-vars.txt" -Encoding UTF8

  # ---------- claude --version ----------
  $claude = (Get-Command claude -ErrorAction SilentlyContinue)
  if ($claude) {
    try { & claude --version 2>&1 | Set-Content "$Stage\claude-version.txt" -Encoding UTF8 } catch {}
  }

  # ---------- source.env (used by claude-restore.ps1 for path remap) ----------
  Log "Writing source.env and MANIFEST.txt"
  @"
SOURCE_HOME=$UserProfile
SOURCE_USER=$env:USERNAME
SOURCE_HOSTNAME=$env:COMPUTERNAME
SOURCE_PLATFORM=Windows
"@ | Set-Content "$Stage\source.env" -Encoding UTF8

  # ---------- Manifest ----------
  $manifest  = "Claude migration archive (Windows)"
  $manifest += "`r`nCreated: $(Get-Date)"
  $manifest += "`r`nSource host: $env:COMPUTERNAME"
  $manifest += "`r`nSource user: $env:USERNAME"
  $manifest += "`r`nSource USERPROFILE: $UserProfile"
  $manifest += "`r`nSource APPDATA: $AppData"
  $manifest += "`r`n"
  $manifest += "`r`n----- Contents (sizes) -----"
  $sizes = Get-ChildItem -Recurse $Stage -ErrorAction SilentlyContinue | ForEach-Object {
    "{0,12} {1}" -f $_.Length, ($_.FullName.Substring($Stage.Length))
  }
  $manifest += "`r`n" + ($sizes -join "`r`n")
  $manifest | Set-Content "$Stage\MANIFEST.txt" -Encoding UTF8

  # ---------- Zip ----------
  Log "Compressing to $OutputPath"
  if (Test-Path $OutputPath) { Remove-Item $OutputPath }
  Compress-Archive -Path "$Stage\*" -DestinationPath $OutputPath -CompressionLevel Optimal

  $sz = [Math]::Round((Get-Item $OutputPath).Length / 1MB, 1)
  Log "Done: $OutputPath ($sz MiB)"
  Log "Copy this file to the new PC and run claude-restore.ps1"
}
finally {
  if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
}
