# Thatch material debug screenshot tool (standard run mode)
# Runs the project normally (no --headless, no Movie Maker) and relies on an
# in-game script to save the viewport to a PNG file.
#
# Why standard run?
#   - Headless / no-window modes cannot render CanvasItem shaders; the viewport
#     texture returns the default gray checkerboard.
#   - Godot Movie Maker works, but writes a PNG sequence and requires cleanup.
#   - A normal project run with a small capture script is the simplest stable
#     path for interactive shader development.
#
# The in-game capture script lives at:
#   modules/building_gen/scripts/debug/capture_in_game.gd
#
# Usage:
#   powershell -File modules/building_gen/tools/capture_standard.ps1
#   Or from project root: .\modules\building_gen\tools\capture_standard.ps1

param(
    [string]$GodotExe = "F:\SteamLibrary\steamapps\common\Godot Engine\Godot_v4.5-stable_mono_win64.exe",
    [string]$ProjectDir = "F:\VSCode\game-2\stick-world",
    [string]$OutputFrame = "modules/building_gen/reference/thatch_debug_capture.png",
    [string]$ScenePath = "",
    [string]$WindowPosition = "10000,10000",
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"

function Resolve-ProjectPath($relativePath) {
    return Join-Path $ProjectDir $relativePath
}

# Validate
if (-not (Test-Path $GodotExe)) {
    Write-Error "Godot executable not found: $GodotExe"
    exit 1
}
if (-not (Test-Path $ProjectDir)) {
    Write-Error "Project directory not found: $ProjectDir"
    exit 1
}

$outputFull = Resolve-ProjectPath $OutputFrame
$outputDir = Split-Path $outputFull -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

# Clean old screenshot so we can detect whether the new one was created.
if (Test-Path $outputFull) {
    Remove-Item -Path $outputFull -Force
}

$arguments = @(
    "--path", $ProjectDir,
    "--position", $WindowPosition
)

if ($ScenePath -ne "") {
    $arguments += $ScenePath
    Write-Host "  Scene:   $ScenePath"
}

Write-Host "[capture_standard] Starting Godot in standard run mode..."
Write-Host "  Project: $ProjectDir"
Write-Host "  Output:  $outputFull"
Write-Host "  Window position: $WindowPosition"

$proc = Start-Process -FilePath $GodotExe `
    -ArgumentList $arguments `
    -WorkingDirectory $ProjectDir `
    -PassThru

try {
    $proc | Wait-Process -Timeout $TimeoutSec -ErrorAction Stop
} catch {
    Write-Warning "[capture_standard] Godot did not exit within ${TimeoutSec}s; killing process."
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

$exitCode = $proc.ExitCode
Write-Host "[capture_standard] Godot exit code: $exitCode"

if ($exitCode -ne 0) {
    Write-Error "Godot failed with exit code $exitCode"
    exit $exitCode
}

if (-not (Test-Path $outputFull)) {
    Write-Error "Screenshot file was not created: $outputFull"
    exit 1
}

$info = Get-Item $outputFull
Write-Host "[capture_standard] Screenshot saved: $outputFull ($($info.Length) bytes, $($info.LastWriteTime))"
