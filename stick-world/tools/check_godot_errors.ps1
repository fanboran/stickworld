# Check Godot errors for stick_world project.
# Two sources are covered:
#   1. Runtime log scan: user://logs (godot.log + rotated godot<timestamp>.log)
#   2. Editor boot simulation (default ON): delete .godot/editor/filesystem_cache10
#      to force full rescan, then run `godot --headless --editor --quit` which
#      reproduces editor-startup errors (resource parse errors like BOM tscn,
#      GDExtension load failures, plugin/@tool errors). ~15s.
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1
#   powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -Quick   # log scan only
#   powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -Warnings
# Exit code: 1 if errors found, 0 if clean.

param(
    [string]$Godot = "F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
    [string]$Project = "F:\VSCode\game-2\stick-world",
    [string]$LogDir = "$env:APPDATA\Godot\app_userdata\stick_world\logs",
    [int]$MaxFiles = 10,
    [int]$Head = 0,
    [switch]$Warnings,
    [switch]$Quick
)

$patterns = "ERROR", "SCRIPT ERROR", "Parse Error", "Invalid call", "Invalid access", "Cannot"
if ($Warnings) { $patterns += "WARNING" }
$totalErrors = 0

# ───────────────────────────── 1. log scan ─────────────────────────────
$files = Get-ChildItem -Path $LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First $MaxFiles

if ($files) {
    foreach ($f in $files) {
        $hits = @()
        Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($p in $patterns) {
                if ($_ -match [regex]::Escape($p)) { $hits += $_; break }
            }
        }
        if ($hits.Count -gt 0) {
            Write-Host ""
            Write-Host "== [log] $($f.Name) ($($hits.Count) hits) ==" -ForegroundColor Cyan
            foreach ($h in $hits) {
                if ($h -match "ERROR|SCRIPT ERROR|Parse Error|Invalid call|Invalid access|Cannot") { $totalErrors++ }
                $color = if ($h -match "WARNING") { "DarkYellow" } else { "Red" }
                Write-Host "  $h" -ForegroundColor $color
            }
        }
    }
} else {
    Write-Host "[check] no log dir: $LogDir" -ForegroundColor Yellow
}

# ───────────────────── 2. editor boot simulation ─────────────────────
if (-not $Quick) {
    Write-Host ""
    Write-Host "== editor boot simulation (delete filesystem_cache10 + --editor --quit) ==" -ForegroundColor Cyan
    $cachePath = Join-Path $Project ".godot\editor\filesystem_cache10"
    if (Test-Path $cachePath) {
        Remove-Item $cachePath -Recurse -Force
    }
    $bootLog = Join-Path $env:TEMP "sw_boot_check.log"
    $bootErr = Join-Path $env:TEMP "sw_boot_check_err.log"
    Remove-Item $bootLog, $bootErr -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Godot -ArgumentList @("--headless", "--editor", "--quit", "--path", $Project) `
        -RedirectStandardOutput $bootLog -RedirectStandardError $bootErr -PassThru -NoNewWindow
    if (-not $p.WaitForExit(300000)) { $p.Kill(); Write-Host "  [boot] TIMEOUT" -ForegroundColor Red; exit 1 }

    $bootHits = @()
    Get-Content $bootLog, $bootErr -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($p in $patterns) {
            if ($_ -match [regex]::Escape($p)) { $bootHits += $_; break }
        }
    }
    # skip the known-benign sqlite GDExtension missing-dll errors? No: they ARE errors; report them.
    if ($bootHits.Count -gt 0) {
        $totalErrors += ($bootHits | Where-Object { $_ -match "ERROR|SCRIPT ERROR|Parse Error|Invalid call|Invalid access|Cannot" }).Count
        foreach ($h in $bootHits) {
            $color = if ($h -match "WARNING") { "DarkYellow" } else { "Red" }
            Write-Host "  $h" -ForegroundColor $color
        }
    } else {
        Write-Host "  [boot] clean (no error lines)" -ForegroundColor Green
    }
}

Write-Host ""
if ($totalErrors -gt 0) {
    Write-Host "=== FOUND $totalErrors errors ===" -ForegroundColor Red
    exit 1
}
Write-Host "=== logs clean: no ERROR / SCRIPT ERROR / Parse Error ===" -ForegroundColor Green
exit 0
