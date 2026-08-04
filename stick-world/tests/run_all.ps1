# Test aggregator: run all test suites and summarize results.
# Usage: powershell -ExecutionPolicy Bypass -File tests\run_all.ps1
# Optional: -Godot <path> -Project <path> -Filter unit|integration|smoke|stage

param(
    [string]$Godot = "F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
    [string]$Project = "F:\VSCode\game-2\stick-world",
    [string]$Filter = ""
)

$ErrorActionPreference = "Continue"

$suites = @{
    "unit" = @(
        "tests/unit/test_placement_grid.tscn",
        "tests/unit/test_health_component.tscn",
        "tests/unit/test_resource_manager.tscn",
        "tests/unit/test_resources_api.tscn",
        "tests/unit/test_organization_manager.tscn",
        "tests/unit/test_entity_states.tscn",
        "tests/unit/test_command_chain.tscn",
        "tests/unit/test_formation_system.tscn",
        "tests/unit/test_behavior_state_machine.tscn"
    )
    "integration" = @(
        "tests/integration/test_construction_cycle.tscn",
        "tests/integration/test_ai_behaviors.tscn",
        "tests/integration/test_game_root_assembly.tscn",
        "tests/integration/test_village_map.tscn",
        "tests/integration/test_battle_lifecycle.tscn",
        "tests/integration/test_selection_formation.tscn",
        "tests/integration/test_possession.tscn",
        "tests/integration/test_formation_presets.tscn",
        "tests/integration/test_squad_travel.tscn",
        "tests/integration/test_melee_combat.tscn",
        "tests/integration/test_combat_feedback.tscn",
        "tests/integration/test_combat_control.tscn",
        "tests/integration/test_menu_navigation.tscn",
        "tests/integration/test_battle_ui.tscn",
        "tests/integration/test_formation_system.tscn",
        "tests/integration/test_placement_grid_units.tscn",
        "tests/integration/test_tactical_orders.tscn"
    )
    "smoke" = @(
        "tests/smoke/test_new_game_smoke.tscn",
        "tests/smoke/test_cross_map_travel.tscn"
    )
    "stage" = @(
    )
}

$timeouts = @{
    "tests/integration/test_battle_lifecycle.tscn" = 120
    "tests/integration/test_selection_formation.tscn" = 90
    "tests/integration/test_possession.tscn" = 90
    "tests/integration/test_village_map.tscn" = 60
    "tests/smoke/test_cross_map_travel.tscn" = 90
    "tests/smoke/test_new_game_smoke.tscn" = 90
}
$defaultTimeout = 45

$totalPassed = 0
$totalFailed = 0
$failures = @()

function Invoke-Test($scene) {
    $timeout = $timeouts[$scene]
    if (-not $timeout) { $timeout = $defaultTimeout }
    $base = [IO.Path]::GetFileNameWithoutExtension($scene)
    $outLog = Join-Path $env:TEMP ("sw_test_" + $base + ".log")
    $errLog = Join-Path $env:TEMP ("sw_test_" + $base + "_err.log")
    Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Godot -ArgumentList @("--headless", "--path", $Project, "res://$scene", "--", "--fresh-start") `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -NoNewWindow
    if (-not $p.WaitForExit($timeout * 1000)) {
        $p.Kill()
        return "TIMEOUT"
    }
    # Godot 重定向输出为 UTF-8（无 BOM），须用 utf8 读取
    $sum = Get-Content $outLog -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -match "测试汇总|\[FAIL\]" } | Select-Object -Last 8
    if (-not $sum) {
        return "FAIL (no summary output)"
    }
    $failedLines = @($sum | Where-Object { $_ -match "\[FAIL\]" })
    if ($failedLines.Count -gt 0) {
        return "FAIL`n$($sum -join "`n")"
    }
    return "PASS"
}

foreach ($group in @("unit", "integration", "smoke", "stage")) {
    if ($Filter -ne "" -and $group -ne $Filter) { continue }
    foreach ($scene in $suites[$group]) {
        if (-not (Test-Path (Join-Path $Project $scene))) {
            Write-Host "[SKIP] $scene (missing)" -ForegroundColor DarkYellow
            continue
        }
        Write-Host "[RUN ] $scene ..." -NoNewline
        $result = Invoke-Test $scene
        if ($result -eq "PASS") {
            $totalPassed++
            Write-Host " PASS" -ForegroundColor Green
        } elseif ($result -eq "TIMEOUT") {
            $totalFailed++
            $failures += "$scene (TIMEOUT)"
            Write-Host " TIMEOUT" -ForegroundColor Red
        } else {
            $totalFailed++
            $failures += $scene
            Write-Host " FAIL" -ForegroundColor Red
            $result -split "`n" | Select-Object -Skip 1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
        }
    }
}

Write-Host ""
Write-Host "=== Summary: $totalPassed passed / $totalFailed failed ==="
if ($failures.Count -gt 0) {
    Write-Host "Failures:"
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
