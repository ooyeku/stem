<#
.SYNOPSIS
    Build stem from source and install it for the current user.

.DESCRIPTION
    Mirrors install.sh on Windows. Runs `zig build -Doptimize=ReleaseFast`,
    copies stem.exe into <Prefix>\bin\, copies the bundled wasm plugins
    into <Prefix>\lib\stem\plugins\, refreshes the per-user plugin dir at
    %USERPROFILE%\.stem\plugins\, and (unless -NoPath) adds the bin dir
    to the user PATH so `stem` works from a fresh shell.

    Default Prefix is %LOCALAPPDATA%\Programs\stem (per-user, no admin
    needed). Override with -Prefix C:\path\to\install.

    Re-running is safe — existing files are overwritten.

.PARAMETER Prefix
    Install root. stem.exe lands at <Prefix>\bin\stem.exe; bundled
    plugins at <Prefix>\lib\stem\plugins\<name>\. Defaults to
    %LOCALAPPDATA%\Programs\stem.

.PARAMETER NoPath
    Skip the user-PATH update.

.EXAMPLE
    .\install.ps1
    Build and install under %LOCALAPPDATA%\Programs\stem.

.EXAMPLE
    .\install.ps1 -Prefix C:\tools\stem
    Install under C:\tools\stem instead.

.EXAMPLE
    .\install.ps1 -NoPath
    Install but leave PATH alone (manage it yourself).

.NOTES
    Requires Zig 0.16+ on PATH. If a previous Stem PATH entry exists
    pointing at the same Prefix, it's left in place; if it points
    somewhere else, the new one is added alongside.
#>

[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA "Programs\stem"),
    [switch]$NoPath
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ">> $msg" -ForegroundColor Cyan
}

# ---- Preflight ----
if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Host "Error: zig is required to build from source." -ForegroundColor Red
    Write-Host "Install Zig 0.16+ from https://ziglang.org/download/ and retry." -ForegroundColor Red
    exit 1
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $repoRoot
try {
    # ---- Build ----
    Write-Step "Building stem (ReleaseFast)..."
    & zig build -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) {
        Write-Host "zig build failed (exit $LASTEXITCODE)." -ForegroundColor Red
        exit $LASTEXITCODE
    }

    $exe = Join-Path $repoRoot "zig-out\bin\stem.exe"
    if (-not (Test-Path $exe)) {
        Write-Host "Error: expected $exe after build, not found." -ForegroundColor Red
        exit 1
    }

    # ---- Install layout ----
    $binDir       = Join-Path $Prefix "bin"
    $pluginDir    = Join-Path $Prefix "lib\stem\plugins"
    $userPlugins  = Join-Path $env:USERPROFILE ".stem\plugins"

    Write-Step "Installing stem.exe to $binDir"
    Write-Step "Installing bundled plugins to $pluginDir"

    New-Item -ItemType Directory -Force -Path $binDir       | Out-Null
    New-Item -ItemType Directory -Force -Path $pluginDir    | Out-Null
    New-Item -ItemType Directory -Force -Path $userPlugins  | Out-Null

    Copy-Item -Force $exe (Join-Path $binDir "stem.exe")

    # ---- Plugins (wasm, ship as <name>/plugin.json + <name>/<name>.wasm) ----
    $plugins = @("echo", "git-wasm", "plugin-manager-wasm")

    function Install-PluginDir($name, $targetRoot) {
        $src = Join-Path $repoRoot "bundled\plugins\$name"
        if (-not (Test-Path $src)) {
            Write-Host "  (skip $name: source dir missing)" -ForegroundColor Yellow
            return
        }
        $dest = Join-Path $targetRoot $name
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null

        $manifest = Join-Path $src "plugin.json"
        if (Test-Path $manifest) {
            Copy-Item -Force $manifest (Join-Path $dest "plugin.json")
        }

        $artifact = Join-Path $repoRoot "zig-out\bin\$name.wasm"
        if (Test-Path $artifact) {
            Copy-Item -Force $artifact (Join-Path $dest "$name.wasm")
        }
    }

    foreach ($p in $plugins) {
        Install-PluginDir -name $p -targetRoot $pluginDir
        Write-Host "  $pluginDir\$p\"
    }

    Write-Host ""
    Write-Step "Refreshing per-user plugin dir: $userPlugins"
    foreach ($p in $plugins) {
        Install-PluginDir -name $p -targetRoot $userPlugins
    }

    # Sweep stale native plugins from older releases — stem no longer
    # has any native plugin loader on Windows; leaving old .dll files
    # in ~/.stem/plugins would just confuse `stem plugin list`.
    Get-ChildItem -Path $userPlugins -Filter "*.dll" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Force $_.FullName
        Write-Host "  removed legacy $($_.FullName)"
    }

    # ---- PATH ----
    if (-not $NoPath) {
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        $entries  = @()
        if ($userPath) {
            $entries = $userPath.Split(";") | Where-Object { $_ -ne "" }
        }
        $alreadyOnPath = $entries | Where-Object {
            ($_.TrimEnd('\') -ieq $binDir.TrimEnd('\'))
        }
        if (-not $alreadyOnPath) {
            $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
            [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
            Write-Step "Added $binDir to user PATH (open a new shell to pick it up)"
        } else {
            Write-Host "  $binDir already on user PATH"
        }
    }

    # ---- Summary ----
    Write-Host ""
    Write-Host "Installed:" -ForegroundColor Green
    Write-Host "  $binDir\stem.exe"
    Write-Host "  $pluginDir\{$($plugins -join ',')}\"
    Write-Host "  $userPlugins\  (refreshed)"

    Write-Host ""
    Write-Host "Optional: install language servers (Python / TS / Go / Rust) with:"
    Write-Host "  stem lsp install all"
}
finally {
    Pop-Location
}
