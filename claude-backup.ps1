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
  [string] $OutputPath = (Join-Path $env:USERPROFILE ("claude-migration-{0}.zip" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),
  [switch] $IncludeProjects,
  [switch] $NoDefaultExcludes
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

  # ---------- Optional: bundle project working trees ----------
  $ProjectsIncluded = "no"
  if ($IncludeProjects) {
    Log "Discovering project paths from .claude.json + Cowork spaces.json"
    $paths = [System.Collections.Generic.HashSet[string]]::new()
    $tooBroad = @($env:USERPROFILE)
    foreach ($d in 'Downloads','Desktop','Documents','Pictures','Music','Videos','OneDrive','AppData') {
      $tooBroad += (Join-Path $env:USERPROFILE $d)
    }

    $claudeJson = "$UserProfile\.claude.json"
    if (Test-Path $claudeJson) {
      try {
        $j = Get-Content -Raw $claudeJson | ConvertFrom-Json
        if ($j.projects) {
          foreach ($k in $j.projects.PSObject.Properties.Name) { [void]$paths.Add($k) }
        }
      } catch {}
    }

    Get-ChildItem -Path "$AppData\Claude\local-agent-mode-sessions\*\*\spaces.json" -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $j = Get-Content -Raw $_.FullName | ConvertFrom-Json
        foreach ($s in $j.spaces) {
          foreach ($fld in $s.folders) {
            if ($fld.path) { [void]$paths.Add($fld.path) }
          }
        }
      } catch {}
    }

    $filtered = $paths | Where-Object {
      $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and ($_ -notin $tooBroad)
    } | Sort-Object

    if (-not $filtered) {
      Log "  no project paths to bundle"
    } else {
      Log ("  found {0} project director(y/ies):" -f $filtered.Count)
      $totalBytes = 0L
      foreach ($p in $filtered) {
        $sz = (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if (-not $sz) { $sz = 0 }
        $totalBytes += $sz
        $human = if ($sz -gt 1GB) { "{0:N1} GB" -f ($sz/1GB) }
                 elseif ($sz -gt 1MB) { "{0:N1} MB" -f ($sz/1MB) }
                 else { "{0:N0} KB" -f ($sz/1KB) }
        "    {0,8}  {1}" -f $human, $p | Write-Host
      }
      $totalHuman = if ($totalBytes -gt 1GB) { "{0:N1} GB" -f ($totalBytes/1GB) }
                    elseif ($totalBytes -gt 1MB) { "{0:N1} MB" -f ($totalBytes/1MB) }
                    else { "{0:N0} KB" -f ($totalBytes/1KB) }
      Log "  total (after default excludes is roughly less): $totalHuman"

      if ($NoDefaultExcludes) {
        Log "  default excludes OFF (-NoDefaultExcludes)"
        $excludeDirs = @()
        $excludeFiles = @()
      } else {
        Log "  default excludes ON (.git, node_modules, __pycache__, .venv, venv, .next, dist, build, target, .idea, .vscode, *.pyc, Thumbs.db, desktop.ini)"
        $excludeDirs = @('.git','node_modules','__pycache__','.venv','venv','.next','dist','build','target','.idea','.vscode')
        $excludeFiles = @('*.pyc','Thumbs.db','desktop.ini','.DS_Store')
      }

      if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $ans = Read-Host "  Proceed with bundling? [y/N]"
        if ($ans -notmatch '^[Yy]') {
          Log "  project bundling cancelled by user"
          exit 0
        }
      } else {
        Log "  no interactive input; proceeding (use -SkipProjects on restore to undo)"
      }

      $projStage = "$Stage\projects"
      New-Item -ItemType Directory -Path $projStage -Force | Out-Null
      $pathsIdx = "$projStage\.paths.txt"
      Set-Content -Path $pathsIdx -Value "" -Encoding UTF8

      foreach ($p in $filtered) {
        # Encode "C:\Users\foo\bar"  ->  "$projStage\C\Users\foo\bar"
        $drive = $p.Substring(0,1)
        $rest  = $p.Substring(3)
        $dst   = Join-Path $projStage (Join-Path $drive $rest)
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Log "  bundling $p"
        $args = @("$p", "$dst", "/E", "/COPY:DAT", "/R:1", "/W:1", "/NFL", "/NDL", "/NP", "/NS", "/NC", "/NJH", "/NJS")
        foreach ($d in $excludeDirs) { $args += "/XD"; $args += $d }
        foreach ($f in $excludeFiles) { $args += "/XF"; $args += $f }
        robocopy @args | Out-Null
        Add-Content -Path $pathsIdx -Value $p -Encoding UTF8
      }
      $ProjectsIncluded = "yes"
      $bundledBytes = (Get-ChildItem -Recurse -File $projStage -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
      $bundledHuman = if ($bundledBytes -gt 1GB) { "{0:N1} GB" -f ($bundledBytes/1GB) }
                      elseif ($bundledBytes -gt 1MB) { "{0:N1} MB" -f ($bundledBytes/1MB) }
                      else { "{0:N0} KB" -f ($bundledBytes/1KB) }
      Log "  total bundled project size after excludes: $bundledHuman"
    }
  }

  # ---------- source.env (used by claude-restore.ps1 for path remap) ----------
  Log "Writing source.env and MANIFEST.txt"
  @"
SOURCE_HOME=$UserProfile
SOURCE_USER=$env:USERNAME
SOURCE_HOSTNAME=$env:COMPUTERNAME
SOURCE_PLATFORM=Windows
PROJECTS_INCLUDED=$ProjectsIncluded
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
