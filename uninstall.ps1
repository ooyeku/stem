<#
.SYNOPSIS
    Remove a stem installation from this machine.

.DESCRIPTION
    Reverses what install.ps1 did:
      - Deletes <Prefix>\bin\stem.exe and <Prefix>\lib\stem\.
      - Removes the bin directory from the user PATH (only the exact
        entry stem added — won't touch unrelated PATH segments).
      - With -Purge, also wipes %APPDATA%\stem and %LOCALAPPDATA%\stem
        (config, recovery backups, installed language servers, search
        cache, logs).

    Safe to re-run; missing pieces are skipped quietly.

.PARAMETER Prefix
    The install prefix to clean. If omitted, probes the two common
    spots (%LOCALAPPDATA%\Programs\stem, %ProgramFiles%\stem) and
    cleans any that contain a stem install.

.PARAMETER Purge
    Also remove %APPDATA%\stem and %LOCALAPPDATA%\stem after a y/N
    prompt. These contain user config and per-user plugins.

.EXAMPLE
    .\uninstall.ps1
    Remove the binary, plugins, and PATH entry from the default
    install location(s).

.EXAMPLE
    .\uninstall.ps1 -Purge
    Same as above plus delete user config / cache after confirmation.

.EXAMPLE
    .\uninstall.ps1 -Prefix C:\tools\stem
    Clean only the install rooted at C:\tools\stem.
#>

[CmdletBinding()]
param(
    [string]$Prefix,
    [switch]$Purge
)

$ErrorActionPreference = "Stop"

function Remove-Under($prefix) {
    if (-not (Test-Path $prefix)) { return $false }

    $bin     = Join-Path $prefix "bin\stem.exe"
    $libRoot = Join-Path $prefix "lib\stem"
    $binDir  = Join-Path $prefix "bin"
    $removed = $false

    if (Test-Path $bin) {
        Remove-Item -Force $bin
        Write-Host "Removed $bin"
        $removed = $true
    }
    if (Test-Path $libRoot) {
        Remove-Item -Recurse -Force $libRoot
        Write-Host "Removed $libRoot"
        $removed = $true
    }

    # Strip $binDir from the user PATH (case-insensitive exact-segment match).
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath) {
        $entries = $userPath.Split(";") | Where-Object { $_ -ne "" }
        $kept = $entries | Where-Object {
            ($_.TrimEnd('\') -ine $binDir.TrimEnd('\'))
        }
        if ($kept.Count -lt $entries.Count) {
            $newPath = ($kept -join ";")
            [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
            Write-Host "Removed $binDir from user PATH"
            $removed = $true
        }
    }

    return $removed
}

$candidates = @()
if ($Prefix) {
    $candidates += $Prefix
} else {
    $candidates += (Join-Path $env:LOCALAPPDATA "Programs\stem")
    $candidates += (Join-Path $env:ProgramFiles "stem")
}

$removedAny = $false
foreach ($c in $candidates) {
    if (Remove-Under $c) { $removedAny = $true }
}

if (-not $removedAny) {
    Write-Host "stem was not found in any of:" -ForegroundColor Yellow
    foreach ($c in $candidates) { Write-Host "  $c" }
}

if ($Purge) {
    $userDirs = @(
        (Join-Path $env:APPDATA      "stem"),
        (Join-Path $env:LOCALAPPDATA "stem")
    )
    foreach ($d in $userDirs) {
        if (Test-Path $d) {
            $reply = Read-Host "Delete $d ? This cannot be undone. [y/N]"
            if ($reply -match '^(y|Y|yes|YES)$') {
                Remove-Item -Recurse -Force $d
                Write-Host "Removed $d"
            } else {
                Write-Host "Skipped $d"
            }
        }
    }
}

Write-Host "Done."
