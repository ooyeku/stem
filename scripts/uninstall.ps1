<#
.SYNOPSIS
    Remove a stem installation from this machine.

.DESCRIPTION
    Reverses what install.ps1 did:
      - Deletes <Prefix>\bin\stem.exe and <Prefix>\lib\stem\.
      - Removes the bin directory from the user PATH (only the
        exact entry stem added — won't touch unrelated PATH segments).
      - With -Purge, also wipes %APPDATA%\stem and
        %LOCALAPPDATA%\stem (config, recovery backups, installed
        language servers, search cache, logs).

    Safe to re-run; missing pieces are skipped quietly.

.PARAMETER Prefix
    The install prefix to clean. If omitted, probes the two common
    spots (LOCALAPPDATA, Program Files) and removes from any that
    contain a stem install.

.PARAMETER Purge
    Also remove user data under %APPDATA%\stem and
    %LOCALAPPDATA%\stem (the equivalent of ~/.stem on POSIX).

.PARAMETER NoPath
    Skip the PATH cleanup step.

.EXAMPLE
    .\uninstall.ps1
    Remove the binary and bundled plugins; keep user data.

.EXAMPLE
    .\uninstall.ps1 -Purge
    Full wipe — also removes config, logs, recovery backups, and
    any LSP servers installed via `stem lsp install`.

.NOTES
    Requires PowerShell 5.1+. No admin rights needed for the
    default per-user install.
#>

[CmdletBinding()]
param(
    [string]$Prefix,
    [switch]$Purge,
    [switch]$NoPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-Info($msg) { Write-Host $msg }
function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Candidate prefixes
# ---------------------------------------------------------------------------

$candidates = @()
if ($Prefix) {
    $candidates += $Prefix
} else {
    # Probe the locations install.ps1 might have used.
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\stem')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'stem')
    }
    if ($env:ProgramW6432 -and $env:ProgramW6432 -ne $env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramW6432 'stem')
    }
}

$removed_any = $false
$pathRemovals = @()

foreach ($p in $candidates) {
    if (-not (Test-Path $p)) { continue }
    $binDir = Join-Path $p 'bin'
    $exe    = Join-Path $binDir 'stem.exe'
    $libDir = Join-Path $p 'lib\stem'

    if (Test-Path $exe) {
        Remove-Item $exe -Force
        Write-Ok "Removed $exe"
        $removed_any = $true
    }
    if (Test-Path $libDir) {
        Remove-Item $libDir -Recurse -Force
        Write-Ok "Removed $libDir"
        $removed_any = $true
    }
    # Try to remove the bin and parent dirs *if* they're now empty.
    foreach ($d in @($binDir, (Join-Path $p 'lib'), $p)) {
        if ((Test-Path $d) -and -not (Get-ChildItem -Path $d -Force)) {
            Remove-Item $d -Force
            Write-Ok "Removed empty dir $d"
        }
    }

    # Stash for PATH cleanup below — even if the dir is gone, we
    # still want to scrub any stale PATH entry.
    $pathRemovals += $binDir
}

# ---------------------------------------------------------------------------
# PATH scrub
# ---------------------------------------------------------------------------

if (-not $NoPath -and $pathRemovals.Count -gt 0) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath) {
        $segs = $userPath.Split(';') | Where-Object { $_ -and $_.Trim().Length -gt 0 }
        $kept = @()
        $dropped = @()
        foreach ($s in $segs) {
            $normalized = try { [System.IO.Path]::GetFullPath($s).TrimEnd('\') } catch { $s.TrimEnd('\') }
            $isStem = $false
            foreach ($removal in $pathRemovals) {
                if ($normalized -ieq $removal.TrimEnd('\')) {
                    $isStem = $true
                    break
                }
            }
            if ($isStem) { $dropped += $s } else { $kept += $s }
        }
        if ($dropped.Count -gt 0) {
            $newPath = ($kept -join ';')
            [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
            foreach ($d in $dropped) { Write-Ok "Removed $d from user PATH" }
            Write-Warn 'Restart your shell to pick up the cleaned PATH.'
        }
    }
}

# ---------------------------------------------------------------------------
# --purge
# ---------------------------------------------------------------------------

if ($Purge) {
    # POSIX ~/.stem maps to two Windows roots:
    #   %APPDATA%\stem        — config + sessions (roaming-class data)
    #   %LOCALAPPDATA%\stem   — caches, logs, installed LSP servers,
    #                            recovery backups (machine-class data)
    $userDirs = @()
    if ($env:APPDATA)      { $userDirs += (Join-Path $env:APPDATA 'stem') }
    if ($env:LOCALAPPDATA) { $userDirs += (Join-Path $env:LOCALAPPDATA 'stem') }
    # POSIX users on this machine via WSL might also have a HOME/.stem.
    if ($env:USERPROFILE)  { $userDirs += (Join-Path $env:USERPROFILE '.stem') }

    foreach ($d in $userDirs) {
        if (Test-Path $d) {
            Remove-Item $d -Recurse -Force
            Write-Ok "Removed $d"
            $removed_any = $true
        }
    }
}

if (-not $removed_any) {
    Write-Info "No stem install found."
    Write-Info "Searched:"
    foreach ($p in $candidates) { Write-Info "  $p" }
    if ($Purge) {
        Write-Info "  %APPDATA%\stem"
        Write-Info "  %LOCALAPPDATA%\stem"
    }
    exit 0
}

Write-Info ''
Write-Info 'stem uninstalled.'
if (-not $Purge) {
    Write-Info ''
    Write-Info 'User data left in place (run with -Purge to remove it):'
    if ($env:APPDATA)      { Write-Info "  $env:APPDATA\stem" }
    if ($env:LOCALAPPDATA) { Write-Info "  $env:LOCALAPPDATA\stem" }
}
