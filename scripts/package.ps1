$ErrorActionPreference = "Stop"

# =============================================================================
# package.ps1 — Build a client-ready delivery zip from the flashback/ folder.
#
# Output:  flashback_<YYYYMMDD_HHMMSS>.zip  (placed in the parent of flashback/)
# Excludes: logs/, config.json, __pycache__, .pytest_cache, _cache_tmp, tests/
#
# Usage (from flashback/ directory):
#   PowerShell -ExecutionPolicy Bypass -File package.ps1
#
# Or from parent directory:
#   PowerShell -ExecutionPolicy Bypass -File .\flashback\package.ps1
# =============================================================================

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root   = Split-Path -Parent $scriptDir
$parent = Split-Path -Parent $root
$ts     = Get-Date -Format "yyyyMMdd_HHmmss"
$outZip = Join-Path $parent ("flashback_{0}.zip" -f $ts)

Write-Output "Oracle Flashback Automation — Packaging"
Write-Output "  Source  : $root"
Write-Output "  Output  : $outZip"
Write-Output ""

# Temp staging area (always in system temp, not the project)
$tmp = Join-Path $env:TEMP ("flashback_pkg_{0}" -f $ts)
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Path $tmp | Out-Null

# Copy the full flashback directory into staging
$stagingDir = Join-Path $tmp "flashback"
Copy-Item -Recurse -Force $root $stagingDir

# ── Remove files that must NOT be shipped to the client ──
$toRemove = @(
    (Join-Path $stagingDir "logs"),
    (Join-Path $stagingDir "config.json"),
    (Join-Path $stagingDir "_cache_tmp"),
    (Join-Path $stagingDir ".cache"),
    (Join-Path $stagingDir ".pytest_cache"),
    (Join-Path $stagingDir "tests"),         # client does not need unit tests
    (Join-Path $stagingDir "__pycache__")
)
foreach ($path in $toRemove) {
    if (Test-Path $path) {
        Write-Output "  Removing : $($path.Replace($stagingDir,''))"
        try { Remove-Item -Recurse -Force $path } catch { }
    }
}

# Remove ALL nested __pycache__ and .pyc files recursively
Get-ChildItem -Path $stagingDir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    ForEach-Object {
        try { Remove-Item -Recurse -Force $_.FullName } catch { }
    }
Get-ChildItem -Path $stagingDir -Recurse -Include "*.pyc","*.pyo" -ErrorAction SilentlyContinue |
    ForEach-Object {
        try { Remove-Item -Force $_.FullName } catch { }
    }

# ── Verify config.example.json is present (client needs the template) ──
$exampleConfig = Join-Path $stagingDir "config.example.json"
if (-Not (Test-Path $exampleConfig)) {
    Write-Warning "WARNING: config.example.json not found in staging. Client may not have config template."
}

# ── Build zip ──
if (Test-Path $outZip) { Remove-Item -Force $outZip }
Compress-Archive -Path $stagingDir -DestinationPath $outZip -CompressionLevel Optimal
Remove-Item -Recurse -Force $tmp

# ── Summary ──
$zipSize = (Get-Item $outZip).Length / 1MB
Write-Output ""
Write-Output "  Done."
Write-Output "  Package : $outZip"
Write-Output "  Size    : {0:F2} MB" -f $zipSize
Write-Output ""
Write-Output "Next steps for client delivery:"
Write-Output "  1. Unzip to the target machine."
Write-Output "  2. Copy config.example.json -> config.json and fill in values."
Write-Output "  3. Edit scripts/oracle/*.sh with real Oracle/SSH connection details."
Write-Output "  4. Run: scripts\run_gui.bat   (Windows)  OR  sh scripts/flashback.sh gui  (Linux/macOS)"
