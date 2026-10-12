#requires -Version 5.1
<#
.SYNOPSIS
  Install a patched msys-2.0.dll that fixes the MSYS2 "add_item ... failed,
  errno 1" concurrent-startup crash for Git for Windows.

.DESCRIPTION
  Matches your installed msys-2.0.dll ProductVersion against baselines.json,
  downloads the matching prebuilt DLL from this repo's Releases, verifies its
  SHA256, backs up the original, replaces it, and verifies with sh probes.
  Auto-elevates when the Git install dir needs admin rights to write.

.PARAMETER GitRoot
  Git for Windows install root (e.g. "D:\Program Files\Git"). Autodetected
  from registry/common paths when omitted.

.PARAMETER Variant
  Default = MOUNT_OVERRIDE patch (msys2-runtime#333);
  Alt = byte-identical duplicate no-op patch (primeinc variant).

.PARAMETER Force
  Skip the interactive confirmation before killing running shells.
#>
[CmdletBinding()]
param(
  [string]$GitRoot,
  [ValidateSet('Default', 'Alt')]
  [string]$Variant = 'Default',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Test-DirWriteAccess([string]$dir) {
  $probe = Join-Path $dir ("writetest-" + [IO.Path]::GetRandomFileName())
  try { [IO.File]::WriteAllText($probe, ''); Remove-Item $probe; return $true }
  catch { return $false }
}

# --- re-launch elevated if needed (keeps params) ---------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Find-GitRoot {
  if ($GitRoot) { return $GitRoot }
  $candidates = @()
  foreach ($hive in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
    if (Test-Path $hive) {
      $v = (Get-ItemProperty $hive -ErrorAction SilentlyContinue).InstallPath
      if ($v) { $candidates += $v }
    }
  }
  $candidates += @(
    "$env:ProgramFiles\Git",
    "${env:ProgramFiles(x86)}\Git",
    "$env:LocalAppData\Programs\Git"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'usr\bin\msys-2.0.dll'))) { return $c }
  }
  throw "Git for Windows not found; pass -GitRoot <path>"
}

$GitRoot = Find-GitRoot
$DllPath = Join-Path $GitRoot 'usr\bin\msys-2.0.dll'
if (-not (Test-Path $DllPath)) { throw "msys-2.0.dll not found: $DllPath" }

$needsAdmin = -not (Test-DirWriteAccess (Split-Path $DllPath -Parent))
if ($needsAdmin -and -not $IsAdmin) {
  Write-Host "Elevating to administrator (writing under $GitRoot)..." -ForegroundColor Yellow
  $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -GitRoot `"$GitRoot`" -Variant $Variant"
  if ($Force) { $arg += ' -Force' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $arg -Wait
  exit $LASTEXITCODE
}

# --- 1. fingerprint installed DLL ------------------------------------------
$ver = (Get-Item $DllPath).VersionInfo.ProductVersion
Write-Host "Installed msys-2.0.dll: $ver  ($GitRoot)"

$base = Join-Path $PSScriptRoot 'baselines.json'
if (-not (Test-Path $base)) { throw "baselines.json not found next to script" }
$cfg = Get-Content $base -Raw | ConvertFrom-Json
$match = $cfg.baselines | Where-Object {
  $ver -and $ver.ToLowerInvariant().StartsWith($_.match_on.ToLowerInvariant())
} | Select-Object -First 1

if (-not $match) {
  Write-Host "`nYour msys-2.0.dll version is not in the supported baselines:" -ForegroundColor Red
  $cfg.baselines | Format-Table id, git_for_windows, match_on -AutoSize | Out-String | Write-Host
  Write-Host "Refusing to patch. Open an issue with the version line above to request support."
  exit 2
}

# --- 2. locate + fetch release asset ----------------------------------------
$variantCfg = if ($Variant -eq 'Alt') { $match.variants.alt } else { $match.variants.default }
$asset = $variantCfg.asset
$repoSlug = $cfg.repo
if ($repoSlug -match 'REPLACE_OWNER') {
  # fall back to this repo's origin when baselines.json is not yet pinned
  $origin = git -C $PSScriptRoot remote get-url origin 2>$null
  if ($origin -match 'github\.com[:/]([^/]+/[^/.]+)') { $repoSlug = $Matches[1] }
}
$urlBase = "https://github.com/$repoSlug/releases/download/$($match.release_tag)"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("msyspatch-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory $tmp | Out-Null
$newDll = Join-Path $tmp $asset
$shaFile = "$newDll.sha256"

Write-Host "Downloading $urlBase/$asset ..."
try {
  Invoke-WebRequest "$urlBase/$asset" -OutFile $newDll -UseBasicParsing
  Invoke-WebRequest "$urlBase/$asset.sha256" -OutFile $shaFile -UseBasicParsing
} catch {
  throw "Download failed. Does release $($match.release_tag) exist with asset $asset? ($_)"
}

$expected = (Get-Content $shaFile -Raw).Trim().Split(' ')[0] -replace '-', ''
$actual = (Get-FileHash $newDll -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw "SHA256 mismatch: expected $expected got $actual" }
Write-Host "SHA256 verified: $actual"

# --- 3. stop processes holding msys-2.0.dll ---------------------------------
$holders = Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and ($_.Path -like "$GitRoot*") } |
  Select-Object Id, ProcessName, Path
if ($holders) {
  $holders | Format-Table -AutoSize | Out-String | Write-Host
  if (-not $Force) {
    $ok = Read-Host "Stop the processes above to replace the DLL? (y/N)"
    if ($ok -notmatch '^[Yy]') { throw "Aborted; close Git Bash/MSYS2 processes and retry." }
  }
  $holders | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

# --- 4. backup + replace -----------------------------------------------------
$bak = "$DllPath.orig"
if (-not (Test-Path $bak)) {
  Copy-Item $DllPath $bak
  Write-Host "Original backed up: $bak  (Restore-Patch.ps1 rolls back to it)"
} else {
  Write-Host "Existing backup kept: $bak"
}

Copy-Item $newDll $DllPath -Force
$newVer = (Get-Item $DllPath).VersionInfo.ProductVersion
Write-Host "Replaced. New ProductVersion: $newVer" -ForegroundColor Green

# --- 5. probe: serial + concurrent starts -----------------------------------
$sh = Join-Path $GitRoot 'usr\bin\sh.exe'
$fail = 0
foreach ($i in 1..3) {
  & $sh -c "exit 0"; if ($LASTEXITCODE -ne 0) { $fail++ }
}
$jobs = 1..8 | ForEach-Object { Start-Process $sh -ArgumentList '-c','exit 0' -PassThru -WindowStyle Hidden }
$jobs | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
$fail += @($jobs | Where-Object { -not $_.HasExited -or $_.ExitCode -ne 0 }).Count

if ($fail -eq 0) {
  Write-Host "Probe passed: 3 serial + 8 concurrent sh starts OK." -ForegroundColor Green
} else {
  Write-Host "Probe reported $fail failure(s). Restore with Restore-Patch.ps1 and report an issue." -ForegroundColor Red
  exit 3
}
