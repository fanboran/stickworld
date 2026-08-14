# Procedural material screenshot tool (standard run mode)
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
#   modules/texture_gen/scripts/debug/capture_in_game.gd
#
# Usage:
#   # Capture the default material (thatch) debug scene
#   powershell -File modules/texture_gen/tools/capture_standard.ps1
#
#   # Capture a specific material by name
#   powershell -File modules/texture_gen/tools/capture_standard.ps1 -Material thatch
#
#   # Explicit scene/output override
#   powershell -File modules/texture_gen/tools/capture_standard.ps1 `
#     -ScenePath "res://modules/texture_gen/materials/thatch/scenes/thatch_debug.tscn" `
#     -OutputFrame "modules/texture_gen/materials/thatch/reference/thatch_debug_capture.png"

param(
    [string]$GodotExe = "F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
    [string]$ProjectDir = "F:\VSCode\game-2\stick-world",
    [string]$Material = "",
    [string]$ScenePath = "",
    [string]$OutputFrame = "",
    [string]$WindowPosition = "10000,10000",
    [int]$TimeoutSec = 90,
    # 渲染驱动：d3d12 (默认, Forward+)、opengl3 (Compatibility)
    # 遇到 D3D12 fragment shader 死代码消除 bug 时改用 opengl3
    [ValidateSet("d3d12", "opengl3", "vulkan")]
    [string]$RenderingDriver = "d3d12"
)

$ErrorActionPreference = "Stop"

function Resolve-ProjectPath($relativePath) {
    return Join-Path $ProjectDir $relativePath
}

function Get-MaterialScenePath($materialName) {
    return "res://modules/texture_gen/materials/$materialName/scenes/${materialName}_debug.tscn"
}

function Get-MaterialOutputPath($materialName) {
    return "modules/texture_gen/materials/$materialName/reference/${materialName}_debug_capture.png"
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

# Resolve material-based defaults if -Material is provided
if ($Material -ne "") {
    $materialDir = Resolve-ProjectPath "modules/texture_gen/materials/$Material"
    if (-not (Test-Path $materialDir)) {
        Write-Error "Material directory does not exist: $materialDir"
        exit 1
    }
    if ($ScenePath -eq "") {
        $ScenePath = Get-MaterialScenePath $Material
    }
    if ($OutputFrame -eq "") {
        $OutputFrame = Get-MaterialOutputPath $Material
    }
}

# Fallback defaults for backward compatibility
if ($OutputFrame -eq "") {
    $OutputFrame = "modules/texture_gen/materials/thatch/reference/thatch_debug_capture.png"
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

# 渲染驱动参数（绕开 D3D12 fragment shader 死代码消除 bug）
if ($RenderingDriver -ne "d3d12") {
    $arguments += "--rendering-driver", $RenderingDriver
    # opengl3 必须同时使用 gl_compatibility 渲染方法
    if ($RenderingDriver -eq "opengl3") {
        $arguments += "--rendering-method", "gl_compatibility"
    }
}

if ($ScenePath -ne "") {
    $arguments += $ScenePath
}

Write-Host "[capture_standard] Starting Godot in standard run mode..."
Write-Host "  Project: $ProjectDir"
Write-Host "  Rendering driver: $RenderingDriver"
if ($Material -ne "") {
    Write-Host "  Material: $Material"
}
if ($ScenePath -ne "") {
    Write-Host "  Scene:   $ScenePath"
}
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
