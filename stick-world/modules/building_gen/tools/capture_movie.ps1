# Thatch material debug screenshot tool
# Uses Godot Movie Maker PNG sequence mode to capture real rendered frames.
#
# Why not headless?
#   In headless / no-window mode, Godot viewport returns default background only.
#   Movie Maker forces real display driver rendering and outputs a PNG sequence.
#   Picking a frame far enough into the sequence gives a stable image.
#
# Usage:
#   powershell -File modules/building_gen/tools/capture_movie.ps1
#   Or from project root: .\modules\building_gen\tools\capture_movie.ps1

param(
    [string]$GodotExe = "F:\SteamLibrary\steamapps\common\Godot Engine\Godot_v4.5-stable_mono_win64.exe",
    [string]$ProjectDir = "F:\VSCode\game-2\stick-world",
    [string]$OutputFrame = "modules/building_gen/reference/thatch_debug_capture.png",
    [string]$MovieBaseName = "modules/building_gen/reference/thatch_movie_frame.png",
    [int]$FrameIndex = 30,
    [int]$Fps = 30,
    [int]$QuitAfter = 60,
    [string]$WindowPosition = "10000,10000"
)

$ErrorActionPreference = "Stop"

function Resolve-ProjectPath($relativePath) {
    return Join-Path $ProjectDir $relativePath
}

function Get-FrameFileName($baseName, $index) {
    $digits = $index.ToString("D8")
    return "{0}{1}.png" -f $baseName, $digits
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

# Clean old frames
# Godot appends 8 zero-padded digits before .png, e.g. basename00000012.png
$movieBaseWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($MovieBaseName)
$movieDir = [System.IO.Path]::GetDirectoryName((Resolve-ProjectPath $MovieBaseName))
$moviePattern = Join-Path $movieDir ($movieBaseWithoutExt + "*.png")
Write-Host "[capture_movie] Cleaning old frames: $moviePattern"
Get-ChildItem -Path $moviePattern -ErrorAction SilentlyContinue | Remove-Item -Force

# Ensure output directory exists
$outputFull = Resolve-ProjectPath $OutputFrame
$outputDir = Split-Path $outputFull -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

# Launch Godot Movie Maker
$arguments = @(
    "--path", $ProjectDir,
    "--write-movie", $MovieBaseName,
    "--quit-after", $QuitAfter,
    "--fixed-fps", $Fps,
    "--position", $WindowPosition
)

Write-Host "[capture_movie] Starting Godot Movie Maker..."
Write-Host "  Project: $ProjectDir"
Write-Host "  Output base name: $MovieBaseName"
Write-Host "  Capturing frame $FrameIndex (rendering $QuitAfter frames total)"

$proc = Start-Process -FilePath $GodotExe `
    -ArgumentList $arguments `
    -WorkingDirectory $ProjectDir `
    -PassThru `
    -Wait

$exitCode = $proc.ExitCode
Write-Host "[capture_movie] Godot exit code: $exitCode"

if ($exitCode -ne 0) {
    Write-Error "Godot failed with exit code $exitCode"
    exit $exitCode
}

# Locate target frame
$targetFrame = Get-FrameFileName (Join-Path $movieDir $movieBaseWithoutExt) $FrameIndex
if (-not (Test-Path $targetFrame)) {
    $existing = Get-ChildItem -Path $moviePattern | Sort-Object Name | Select-Object -Last 1
    if ($existing -eq $null) {
        Write-Error "No PNG frames were generated"
        exit 1
    }
    Write-Warning "Frame $FrameIndex not found, falling back to last frame: $($existing.Name)"
    $targetFrame = $existing.FullName
}

# Copy to final output and clean intermediate frames
Copy-Item -Path $targetFrame -Destination $outputFull -Force
Write-Host "[capture_movie] Screenshot saved: $outputFull"

Get-ChildItem -Path $moviePattern -ErrorAction SilentlyContinue | Remove-Item -Force

# Verify
if (-not (Test-Path $outputFull)) {
    Write-Error "Final screenshot file was not created"
    exit 1
}

$info = Get-Item $outputFull
Write-Host "[capture_movie] Done. File size: $($info.Length) bytes"
