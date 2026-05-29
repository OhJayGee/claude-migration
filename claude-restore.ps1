# claude-restore.ps1 — restore a Windows backup produced by claude-backup.ps1.
#
# Usage (PowerShell):
#   .\claude-restore.ps1 -Archive C:\path\claude-migration-<ts>.zip
#   .\claude-restore.ps1 -Archive ... -DryRun
#   .\claude-restore.ps1 -Archive ... -RemapTo newuser
#   .\claude-restore.ps1 -Archive ... -NoRemap
#
# Behavior:
#   - Stops Claude.exe if running (it caches state on disk and will overwrite restored files on exit).
#   - Moves any existing %USERPROFILE%\.claude, .claude.json, and overwritten %APPDATA%\Claude\
#     items into %USERPROFILE%\claude-pre-restore-<timestamp>\ before writing.
#   - Restores all captured files.
#   - If the source username differs from the destination's, prompts to rewrite
#     C:\Users\OLDUSER\ -> C:\Users\NEWUSER\ and the equivalent encoded form
#     (-C--Users-OLDUSER- -> -C--Users-NEWUSER-) inside .json / .jsonl / .md / .txt files
#     under the same scope as the macOS version, and renames the encoded project dirs.
#   - Prints the env-vars list and a TODO checklist for OAuth re-login, MCP servers, etc.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Archive,
  [switch] $DryRun,
  [switch] $NoRemap,
  [switch] $SkipProjects,
  [string] $RemapTo = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Archive)) {
  Write-Error "Archive not found: $Archive"
}

function Log { param([string]$Msg) Write-Host "[restore] $Msg" }

# ---------- Extract ----------
$Work = Join-Path $env:TEMP ("claude-restore-{0}" -f ([System.Guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $Work | Out-Null
Log "Extracting $Archive -> $Work"
Expand-Archive -Path $Archive -DestinationPath $Work -Force
$Stage = $Work
if (-not (Test-Path "$Stage\source.env") -and (Test-Path "$Stage\claude-migration\source.env")) {
  $Stage = "$Work\claude-migration"
}
if (-not (Test-Path "$Stage\source.env")) {
  Write-Error "Archive does not contain source.env — wrong file?"
}

# ---------- Parse source.env ----------
$sourceVars = @{}
Get-Content "$Stage\source.env" | ForEach-Object {
  if ($_ -match '^([A-Z_]+)=(.*)$') { $sourceVars[$matches[1]] = $matches[2] }
}
$SourceHome = $sourceVars["SOURCE_HOME"]
$SourceUser = $sourceVars["SOURCE_USER"]
$SourcePlatform = $sourceVars["SOURCE_PLATFORM"]

if ($SourcePlatform -ne "Windows") {
  Write-Warning "Archive was created on $SourcePlatform, not Windows. Cross-platform restore is NOT supported by this script."
  Write-Warning "Path encoding differs (macOS uses '-Users-', Windows uses '-C--Users-'). Aborting."
  exit 2
}

$DestHome = $env:USERPROFILE
$DestUser = if ($RemapTo) { $RemapTo } else { $env:USERNAME }
if ($RemapTo) { $DestHome = "C:\Users\$RemapTo" }

$NeedRemap = ($SourceHome -ne $DestHome)

Log "Source: USERPROFILE=$SourceHome user=$SourceUser"
Log "This:   USERPROFILE=$DestHome user=$DestUser"
if ($NeedRemap) {
  if ($NoRemap) {
    Log "Usernames differ but -NoRemap given — paths will NOT be rewritten."
  } else {
    Log "Usernames differ — paths will be rewritten after restore."
  }
} else {
  Log "Usernames match — no path remap needed."
}

# ---------- Dry run ----------
if ($DryRun) {
  Log "DRY-RUN — would restore the following paths:"
  if (Test-Path "$Stage\home") {
    Get-ChildItem -Path "$Stage\home" -Force | ForEach-Object { "  $env:USERPROFILE\$($_.Name)" }
  }
  if (Test-Path "$Stage\appdata\Claude") {
    Get-ChildItem -Path "$Stage\appdata\Claude" -Force | ForEach-Object { "  $env:APPDATA\Claude\$($_.Name)" }
  }
  if ($NeedRemap -and -not $NoRemap) {
    Write-Host ""
    Log "DRY-RUN — would then rewrite paths:"
    Write-Host "    C:\Users\$SourceUser\  ->  C:\Users\$DestUser\"
    Write-Host "    -C--Users-$SourceUser-  ->  -C--Users-$DestUser-"
  }
  Remove-Item -Recurse -Force $Work
  exit 0
}

# ---------- Confirmation ----------
Write-Host ""
Log "This will overwrite existing Claude config on this PC."
$Pre = Join-Path $env:USERPROFILE ("claude-pre-restore-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Log "Pre-existing files will first be moved to: $Pre"
$ans = Read-Host "Continue? [y/N]"
if ($ans -notmatch '^[Yy]') { Log "Aborted."; exit 0 }
New-Item -ItemType Directory -Path $Pre | Out-Null

# ---------- Quit Claude.app ----------
$claudeProc = Get-Process -Name Claude -ErrorAction SilentlyContinue
if ($claudeProc) {
  Log "Quitting Claude to prevent it from overwriting restored files"
  $claudeProc | Stop-Process -Force
  Start-Sleep -Seconds 2
}

function Move-Aside {
  param([string]$Path)
  if (Test-Path $Path) {
    $rel = $Path.Substring($env:USERPROFILE.Length).TrimStart('\')
    $dst = Join-Path $Pre $rel
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Move-Item -Path $Path -Destination $dst
    Log "  moved aside: $Path"
  }
}

# ---------- Move-aside existing ----------
Move-Aside "$env:USERPROFILE\.claude"
Move-Aside "$env:USERPROFILE\.claude.json"
Move-Aside "$env:USERPROFILE\.claudeignore"

# ---------- Restore home ----------
Log "Restoring .claude.json and .claude\"
if (Test-Path "$Stage\home") {
  Copy-Item -Recurse -Force "$Stage\home\*" $env:USERPROFILE
}

# ---------- Restore Desktop ----------
$DesktopDst = Join-Path $env:APPDATA "Claude"
New-Item -ItemType Directory -Path $DesktopDst -Force | Out-Null
if (Test-Path "$Stage\appdata\Claude") {
  Log "Restoring Claude Desktop files into $DesktopDst"
  Get-ChildItem -Path "$Stage\appdata\Claude" -Force | ForEach-Object {
    $target = Join-Path $DesktopDst $_.Name
    if (Test-Path $target) {
      $rel = $target.Substring($env:USERPROFILE.Length).TrimStart('\')
      $dst = Join-Path $Pre $rel
      $dstDir = Split-Path $dst -Parent
      if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
      Move-Item -Path $target -Destination $dst -Force
      Log "  moved aside: $target"
    }
    Copy-Item -Recurse -Force $_.FullName $DesktopDst
    Log "  restored: $target"
  }
}

# ---------- Path remap ----------
function Remap-Paths {
  param([string]$SrcUser, [string]$DstUser)

  $srcAbs = "C:\Users\$SrcUser\"
  $dstAbs = "C:\Users\$DstUser\"
  $srcEnc = "-C--Users-$SrcUser-"
  $dstEnc = "-C--Users-$DstUser-"

  Log "[remap] Rewriting paths: $srcAbs -> $dstAbs"
  Log "[remap] Rewriting encoded: $srcEnc -> $dstEnc"

  # 1. Rename ~/.claude/projects/-C--Users-<SrcUser>-... directories.
  $projDir = Join-Path $env:USERPROFILE ".claude\projects"
  if (Test-Path $projDir) {
    Get-ChildItem -Directory -Path $projDir | Where-Object { $_.Name.StartsWith($srcEnc) } | ForEach-Object {
      $newName = $dstEnc + $_.Name.Substring($srcEnc.Length)
      Log ("[remap]   {0} -> {1}" -f $_.Name, $newName)
      Rename-Item -Path $_.FullName -NewName $newName
    }
  }

  # 2. In-place rewrites inside known JSON/JSONL/MD/TXT files.
  $roots = @(
    "$env:USERPROFILE\.claude.json",
    "$env:USERPROFILE\.claude",
    "$env:APPDATA\Claude\claude_desktop_config.json",
    "$env:APPDATA\Claude\config.json",
    "$env:APPDATA\Claude\Claude Extensions Settings",
    "$env:APPDATA\Claude\claude-code-sessions",
    "$env:APPDATA\Claude\local-agent-mode-sessions"
  )

  # PowerShell needs to match both forms in JSON: literal C:\ paths AND the
  # JSON-escaped C:\\ form (each backslash becomes \\ in JSON string values).
  $replacements = @(
    @{ Old = $srcAbs;                                         New = $dstAbs },
    @{ Old = $srcAbs.Replace('\','\\');                       New = $dstAbs.Replace('\','\\') },
    @{ Old = $srcEnc;                                         New = $dstEnc }
  )

  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $files = if ((Get-Item $root).PSIsContainer) {
      Get-ChildItem -Recurse -File -Path $root -Include *.json,*.jsonl,*.md,*.txt -ErrorAction SilentlyContinue
    } else {
      @(Get-Item $root)
    }
    foreach ($f in $files) {
      try {
        $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop
        $orig = $content
        foreach ($r in $replacements) {
          $content = $content.Replace($r.Old, $r.New)
        }
        if ($content -ne $orig) {
          Set-Content -LiteralPath $f.FullName -Value $content -Encoding UTF8 -NoNewline
        }
      } catch {}
    }
  }

  Log "[remap] Done."
}

if ($NeedRemap -and -not $NoRemap) {
  Write-Host ""
  $ans = Read-Host "[remap] Rewrite paths from C:\Users\$SourceUser\ to C:\Users\$DestUser\? [Y/n]"
  if ($ans -eq "" -or $ans -match '^[Yy]') {
    Remap-Paths -SrcUser $SourceUser -DstUser $DestUser
  } else {
    Log "[remap] Skipped."
  }
}

# ---------- Optional: restore bundled project working trees ----------
$projStage = Join-Path $Stage "projects"
$pathsIdx  = Join-Path $projStage ".paths.txt"
if (-not $SkipProjects -and (Test-Path $projStage) -and (Test-Path $pathsIdx)) {
  $entries = Get-Content $pathsIdx | Where-Object { $_ -and $_.Trim() }
  $count = $entries.Count
  $bytes = (Get-ChildItem -Recurse -File $projStage -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  $human = if ($bytes -gt 1GB) { "{0:N1} GB" -f ($bytes/1GB) }
           elseif ($bytes -gt 1MB) { "{0:N1} MB" -f ($bytes/1MB) }
           else { "{0:N0} KB" -f ($bytes/1KB) }
  Write-Host ""
  Log "Archive includes $count project director(y/ies), total $human."
  Log "Each will be restored to its original path (with username remap if needed)."
  Log "Existing directories at those paths will be moved aside to $Pre\projects\."
  $ans = Read-Host "Restore project trees now? [Y/n]"
  if ($ans -eq "" -or $ans -match '^[Yy]') {
    foreach ($srcPath in $entries) {
      # Decode "$projStage\C\Users\foo\bar" back to "C:\Users\foo\bar"
      $drive = $srcPath.Substring(0,1)
      $rest  = $srcPath.Substring(3)
      $stagePath = Join-Path $projStage (Join-Path $drive $rest)
      if (-not (Test-Path $stagePath)) {
        Log "  missing in archive, skipping: $srcPath"
        continue
      }

      $dstPath = $srcPath
      if ($NeedRemap -and -not $NoRemap) {
        $dstPath = $srcPath -replace ("\\Users\\" + [regex]::Escape($SourceUser) + "\\"), ("\Users\$DestUser\")
      }

      if (Test-Path -LiteralPath $dstPath) {
        $rel = $dstPath.Substring(0,1) + $dstPath.Substring(2)  # "C:\Users\..."  ->  "C\Users\..."
        $bakDir = Join-Path $Pre (Join-Path "projects" $rel)
        $parent = Split-Path $bakDir -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Move-Item -LiteralPath $dstPath -Destination $bakDir -Force
        Log "  moved aside existing: $dstPath"
      }
      New-Item -ItemType Directory -Path $dstPath -Force | Out-Null
      robocopy "$stagePath" "$dstPath" /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NP /NS /NC /NJH /NJS | Out-Null
      Log "  restored: $dstPath"
    }
  } else {
    Log "Project tree restore skipped."
  }
}

# ---------- Cleanup + post-restore notes ----------
Remove-Item -Recurse -Force $Work

Write-Host ""
Log "Restore complete."
Write-Host ""
Write-Host "Pre-restore backup of any overwritten files: $Pre"
Write-Host ""
Write-Host "Next steps on this PC:"
Write-Host "  1. Re-authenticate Claude Code:    claude   (then OAuth login in the browser)"
Write-Host "  2. Verify CLI MCP servers:         claude mcp list"
Write-Host "  3. Launch Claude.exe and sign in.  MCP extensions and Cowork sessions should appear."
Write-Host "  4. Reinstall the Claude Code CLI if needed (this script does not install the binary)."
Write-Host ""
if (Test-Path "$Stage\env-vars.txt") {
  $envContent = Get-Content "$Stage\env-vars.txt" -Raw
  if ($envContent.Trim()) {
    Write-Host "User env vars detected on the source PC — add them to this PC's environment if you still want them:"
    Write-Host "----"
    Write-Host $envContent
    Write-Host "----"
  }
}
Write-Host ""
Write-Host "Web/desktop chat 'Memory' (the cross-conversation memory) is stored server-side per"
Write-Host "account and does NOT transfer through filesystem migration. To move it, use the"
Write-Host "official export/import flow:"
Write-Host "  https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude"
