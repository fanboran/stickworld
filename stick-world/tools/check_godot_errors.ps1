# Check Godot log errors for stick_world project.
# Scans user://logs (godot.log + rotated godot<timestamp>.log) and prints ERROR /
# SCRIPT ERROR / Parse Error / WARNING lines with file:line context.
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1
#   powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -Warnings   # include warnings
#   powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -Head 5    # show first N errors
# Exit code: 1 if errors found, 0 if clean (warnings only => 0).

param(
    [string]$LogDir = "$env:APPDATA\Godot\app_userdata\stick_world\logs",
    [int]$MaxFiles = 10,
    [int]$Head = 0,
    [switch]$Warnings
)

$patterns = "ERROR", "SCRIPT ERROR", "Parse Error", "Invalid call", "Invalid access", "Cannot"
if ($Warnings) { $patterns += "WARNING" }

$files = Get-ChildItem -Path $LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First $MaxFiles

if (-not $files) {
    Write-Host "[check-godot-errors] no log dir: $LogDir" -ForegroundColor Yellow
    exit 0
}

$errorCount = 0
$firstErrors = @()
foreach ($f in $files) {
    $hits = @()
    Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($p in $patterns) {
            if ($_ -match [regex]::Escape($p)) { $hits += $_; break }
        }
    }
    if ($hits.Count -gt 0) {
        Write-Host ""
        Write-Host "== $($f.Name) ($($hits.Count)) ==" -ForegroundColor Cyan
        foreach ($h in $hits) {
            if ($h -match "ERROR|SCRIPT ERROR|Parse Error|Invalid call|Invalid access|Cannot") {
                $errorCount++
                $firstErrors += "$($f.Name): $h"
            }
            $color = if ($h -match "WARNING") { "DarkYellow" } else { "Red" }
            Write-Host "  $h" -ForegroundColor $color
        }
    }
}

Write-Host ""
if ($errorCount -gt 0) {
    Write-Host "=== FOUND $errorCount errors in logs ===" -ForegroundColor Red
    if ($Head -gt 0) {
        Write-Host "--- first $Head ---"
        $firstErrors | Select-Object -First $Head | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    exit 1
}
Write-Host "=== logs clean: no ERROR / SCRIPT ERROR / Parse Error ===" -ForegroundColor Green
exit 0
