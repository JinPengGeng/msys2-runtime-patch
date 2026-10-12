#requires -Version 5.1
<#
.SYNOPSIS
  Roll back Apply-Patch.ps1: restore the original msys-2.0.dll backup.
#>
[CmdletBinding()]
param(
  [string]$GitRoot,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $GitRoot) {
  foreach ($hive in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
    if (Test-Path $hive) {
      $v = (Get-ItemProperty $hive -ErrorAction SilentlyContinue).InstallPath
      if ($v -and (Test-Path (Join-Path $v 'usr\bin\msys-2.0.dll'))) { $GitRoot = $v; break }
    }
  }
}
if (-not $GitRoot) { throw "Git for Windows not found; pass -GitRoot <path>" }

$DllPath = Join-Path $GitRoot 'usr\bin\msys-2.0.dll'
$bak = "$DllPath.orig"
if (-not (Test-Path $bak)) { throw "No backup found: $bak" }

try {
  $fs = [IO.File]::Open($DllPath, 'Open', 'ReadWrite', 'None'); $fs.Close()
} catch {
  if (-not $IsAdmin) {
    Write-Host "Elevating to administrator..." -ForegroundColor Yellow
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -GitRoot `"$GitRoot`""
    if ($Force) { $arg += ' -Force' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arg -Wait
    exit $LASTEXITCODE
  }
  throw
}

$holders = Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and ($_.Path -like "$GitRoot*") }
if ($holders) {
  $holders | Select-Object Id, ProcessName | Format-Table -AutoSize | Out-String | Write-Host
  if (-not $Force) {
    $ok = Read-Host "Stop the processes above? (y/N)"
    if ($ok -notmatch '^[Yy]') { throw "Aborted." }
  }
  $holders | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

Copy-Item $bak $DllPath -Force
$ver = (Get-Item $DllPath).VersionInfo.ProductVersion
Write-Host "Restored original msys-2.0.dll: $ver" -ForegroundColor Green
& (Join-Path $GitRoot 'usr\bin\sh.exe') -c "exit 0"
if ($LASTEXITCODE -eq 0) { Write-Host "Probe OK." -ForegroundColor Green }
