<#
.SYNOPSIS
    Install stem from a prebuilt GitHub release.

.DESCRIPTION
    Downloads the matching prebuilt tarball for this Windows host,
    verifies its SHA-256 (when published), extracts it, copies the
    binary and bundled wasm plugins into place, and adds the install
    directory to the user PATH. Mirrors the behavior of the POSIX
    install.sh.

    Default install prefix is %LOCALAPPDATA%\Programs\stem (per-user,
    no admin required). Override with -Prefix.

.PARAMETER Version
    Pin a specific release tag (e.g. v0.6.0). Defaults to the latest
    published release.

.PARAMETER Prefix
    Install root. The binary lands at <Prefix>\bin\stem.exe and the
    bundled plugins at <Prefix>\lib\stem\plugins\. Defaults to
    %LOCALAPPDATA%\Programs\stem.

.PARAMETER NoPath
    Skip the user-PATH update step. Useful for sandboxed installs
    where you'll wire PATH yourself.

.PARAMETER Force
    Overwrite an existing install without prompting.

.EXAMPLE
    .\install.ps1
    Install the latest release into the default per-user prefix.

.EXAMPLE
    irm https://raw.githubusercontent.com/ooyeku/stem/main/scripts/install.ps1 | iex
    One-liner install in PowerShell 5.1+.

.EXAMPLE
    .\install.ps1 -Version v0.6.0 -Prefix C:\tools\stem
    Pinned version, custom prefix.

.NOTES
    Requires PowerShell 5.1+ and `tar.exe` (built-in on Windows 10
    1803 and later). For older systems install the optional
    `bsdtar` from Microsoft, or run install.sh under WSL.
#>

[CmdletBinding()]
param(
    [string]$Version = $env:STEM_VERSION,
    [string]$Prefix  = $env:STEM_PREFIX,
    [switch]$NoPath,
    [switch]$Force
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Stop on the first error; opt into PS 7-style strict mode.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Older Windows defaults to TLS 1.0/1.1 which github.com no longer
# accepts. Force TLS 1.2 for the install session.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$REPO = 'ooyeku/stem'

function Write-Info($msg)  { Write-Host $msg }
function Write-Step($msg)  { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "  $msg" -ForegroundColor Yellow }
function Stop-WithError($msg) {
    Write-Host "error: $msg" -ForegroundColor Red
    exit 1
}

function Require-Command([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Stop-WithError "missing required command: $name"
    }
}

Require-Command tar

# ---------------------------------------------------------------------------
# Arch + target detection
# ---------------------------------------------------------------------------

$arch_label = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default {
        Stop-WithError "unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
    }
}
$target = "$arch_label-windows"

# ---------------------------------------------------------------------------
# Prefix
# ---------------------------------------------------------------------------

if (-not $Prefix) {
    if (-not $env:LOCALAPPDATA) {
        Stop-WithError 'LOCALAPPDATA not set; pass -Prefix or set STEM_PREFIX.'
    }
    $Prefix = Join-Path $env:LOCALAPPDATA 'Programs\stem'
}
# Normalize so we have a clean absolute path even if the caller used /.
$Prefix = (New-Item -ItemType Directory -Path $Prefix -Force).FullName

$binDir     = Join-Path $Prefix 'bin'
$pluginsDir = Join-Path $Prefix 'lib\stem\plugins'
$exePath    = Join-Path $binDir 'stem.exe'

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------

if (-not $Version) {
    Write-Info 'Resolving latest stem release...'
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases/latest" -UseBasicParsing
        $Version = $rel.tag_name
    } catch {
        # Fall back to the full release list (prereleases included).
        try {
            $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases" -UseBasicParsing
            if ($rels -and $rels.Count -gt 0) { $Version = $rels[0].tag_name }
        } catch { }
    }
    if (-not $Version) {
        Stop-WithError "could not resolve latest version. Pass -Version vX.Y.Z."
    }
}
Write-Info "Installing stem $Version for $target"
Write-Info "Prefix: $Prefix"

# ---------------------------------------------------------------------------
# Existing-install check
# ---------------------------------------------------------------------------

if ((Test-Path $exePath) -and -not $Force) {
    Write-Warn "stem.exe already present at $exePath"
    $resp = Read-Host '  Overwrite? [y/N]'
    if ($resp -notmatch '^[Yy]') {
        Write-Info 'Aborted.'
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

$archive = "stem-$Version-$target.tar.gz"
$url     = "https://github.com/$REPO/releases/download/$Version/$archive"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("stem-install-" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp -Force)
try {
    $tarPath = Join-Path $tmp $archive
    Write-Step "Downloading $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tarPath -UseBasicParsing
    } catch {
        Stop-WithError @"
download failed: $url

The release '$Version' may not have a prebuilt Windows binary for $arch_label.
Visit https://github.com/$REPO/releases to see what's available, or pass
-Version vX.Y.Z to choose a different tag.
"@
    }

    # ---------------------------------------------------------------------------
    # Checksum (best-effort: only when .sha256 is published)
    # ---------------------------------------------------------------------------

    $sumPath = "$tarPath.sha256"
    try {
        Invoke-WebRequest -Uri "$url.sha256" -OutFile $sumPath -UseBasicParsing -ErrorAction Stop
        $expected = (Get-Content $sumPath -Raw).Trim().Split()[0].ToLower()
        $actual   = (Get-FileHash $tarPath -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Stop-WithError "checksum mismatch: expected $expected, got $actual"
        }
        Write-Ok "SHA-256 verified"
    } catch [System.Net.WebException] {
        Write-Warn 'No .sha256 file published; skipping integrity check.'
    } catch {
        # Any non-network error is real — rethrow.
        throw
    }

    # ---------------------------------------------------------------------------
    # Extract
    # ---------------------------------------------------------------------------

    $extractDir = Join-Path $tmp 'extract'
    [void](New-Item -ItemType Directory -Path $extractDir -Force)
    Write-Step "Extracting"
    & tar.exe -xzf $tarPath -C $extractDir
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "tar extraction failed (exit $LASTEXITCODE)"
    }

    # ---------------------------------------------------------------------------
    # Install binary
    # ---------------------------------------------------------------------------

    [void](New-Item -ItemType Directory -Path $binDir -Force)
    $srcExe = Get-ChildItem -Path $extractDir -Recurse -Filter 'stem.exe' | Select-Object -First 1
    if (-not $srcExe) {
        Stop-WithError "stem.exe not found inside the archive — looks like a broken release?"
    }
    Copy-Item -Path $srcExe.FullName -Destination $exePath -Force
    Write-Ok "Installed $exePath"

    # ---------------------------------------------------------------------------
    # Bundled plugins (if shipped inside the tarball)
    # ---------------------------------------------------------------------------

    $srcPlugins = Get-ChildItem -Path $extractDir -Recurse -Directory -Filter 'plugins' |
                  Where-Object { $_.Parent.Name -eq 'stem' } |
                  Select-Object -First 1
    if (-not $srcPlugins) {
        # Older release layout — plugins might be at bundled/plugins.
        $srcPlugins = Get-ChildItem -Path $extractDir -Recurse -Directory -Filter 'plugins' |
                      Where-Object { $_.Parent.Name -eq 'bundled' } |
                      Select-Object -First 1
    }
    if ($srcPlugins) {
        [void](New-Item -ItemType Directory -Path $pluginsDir -Force)
        Copy-Item -Path (Join-Path $srcPlugins.FullName '*') -Destination $pluginsDir -Recurse -Force
        Write-Ok "Installed plugins to $pluginsDir"
    }

    # ---------------------------------------------------------------------------
    # PATH
    # ---------------------------------------------------------------------------

    if (-not $NoPath) {
        $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        $segs = if ($userPath) {
            $userPath.Split(';') | Where-Object { $_ -and $_.Trim().Length -gt 0 }
        } else { @() }
        $already = $segs | Where-Object {
            try { [System.IO.Path]::GetFullPath($_).TrimEnd('\') -ieq $binDir.TrimEnd('\') }
            catch { $false }
        }
        if (-not $already) {
            $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
            [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
            Write-Ok "Added $binDir to user PATH"
            Write-Warn 'Restart your shell (or sign out/in) to pick up the new PATH.'
        } else {
            Write-Ok "$binDir already on user PATH"
        }
    }

    # ---------------------------------------------------------------------------
    # Done
    # ---------------------------------------------------------------------------

    Write-Info ''
    Write-Info 'stem installed.'
    Write-Info "  Binary:  $exePath"
    if (Test-Path $pluginsDir) {
        Write-Info "  Plugins: $pluginsDir"
    }
    Write-Info ''
    Write-Info "Try it:   stem --version"
    Write-Info "Or:       & '$exePath' --version"
}
finally {
    if (Test-Path $tmp) {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
