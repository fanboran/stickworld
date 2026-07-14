# 世界生成参考开源库一键 clone 脚本
# 用法：在系统 PowerShell（不是 IDE 终端）中执行：
#   cd f:\VSCode\game-2
#   powershell -ExecutionPolicy Bypass -File tools\worldgen\clone_externals.ps1
#
# 说明：IDE 的 RunCommand 在 trae-sandbox 下执行，sandbox 屏蔽网络。
#       必须在系统 PowerShell 中运行本脚本。
#
# 所有 repo 都用 --depth 1 浅克隆，只取最新 commit，节省空间和带宽。
# external/ 已在 .gitignore 中排除，不会污染 Git 历史。
#
# 环境变量（可选）：
#   $env:GITHUB_MIRROR  — GitHub 镜像前缀，例如 "https://gh-proxy.com/"
#                         当 GitHub 直连 SSL 握手失败时设置。
#                         镜像会同时用于 git clone 和 ZIP 兜底下载。
#   $env:CLONE_TMPDIR   — 临时目录，例如 "F:\VSCode\game-2\.tmp"
#                         当系统 %TEMP% 所在盘已满时设置，避免 "No space left on device"。

$ErrorActionPreference = "Stop"
$root = "f:\VSCode\game-2\external"
if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root | Out-Null }

# 镜像前缀（可为空 = 直连 GitHub）
$mirror = $env:GITHUB_MIRROR
if ($mirror -and -not $mirror.EndsWith("/")) { $mirror += "/" }

# 临时目录：优先用 $env:CLONE_TMPDIR，否则用系统 $env:TEMP
$tmpDir = $env:CLONE_TMPDIR
if ($tmpDir) {
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $env:TMP = $tmpDir
    $env:TEMP = $tmpDir
    $env:TMPDIR = $tmpDir
}

# 把 GitHub URL 包装上镜像前缀（若设置）
function Wrap-Url([string]$url) {
    if ($mirror) { return "$mirror$url" } else { return $url }
}

# 通过 GitHub API 探测仓库默认分支（失败时返回 $null）
function Get-DefaultBranch([string]$ownerRepo) {
    $apiUrl = "https://api.github.com/repos/$ownerRepo"
    $apiUrl = Wrap-Url $apiUrl
    try {
        # -UseBasicParsing 避免 IE 引擎依赖；超时 20s
        $resp = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 20 `
            -Headers @{ "User-Agent" = "clone_externals.ps1" }
        $obj = $resp.Content | ConvertFrom-Json
        return $obj.default_branch
    } catch {
        return $null
    }
}

# 要 clone 的项目清单（基于 docs/设计/系统/程序化世界生成.md 引用）
$repos = @(
    # Azgaar Fantasy-Map-Generator - §5.2/5.3/5.4/八 多处引用，最重要
    # 模板法地形生成（Hill/Range/Pit/Trough）、温湿矩阵、河流水文、受限 Voronoi
    @{ name = "Fantasy-Map-Generator"; url = "https://github.com/Azgaar/Fantasy-Map-Generator.git" }
    ,
    # World-Synth - §5.2 引用，BFS 板块生长 + cost function 参考
    @{ name = "world-synth"; url = "https://github.com/kenjinp/world-synth.git" }
    ,
    # Unciv - §5.1/5.3 引用，8 种大陆模式 + 温湿矩阵参考
    @{ name = "Unciv"; url = "https://github.com/yairm210/Unciv.git" }
    ,
    # againey/planet-generator - Experilous 的 fork（原网站 experilous.com 已下线）
    # §5.2 引用 Experilous 板块应力模拟 + 岛弧生成
    @{ name = "planet-generator-experilous-fork"; url = "https://github.com/againey/planet-generator.git" }
    ,
    # caseymcc/worldgen - C++ 板块构造 + 天气单元实现参考（参考 Experilous）
    @{ name = "worldgen-cpp"; url = "https://github.com/caseymcc/worldgen.git" }
)

Write-Host "将 clone $($repos.Count) 个仓库到 $root" -ForegroundColor Cyan
if ($mirror) { Write-Host "镜像前缀: $mirror" -ForegroundColor Cyan }
if ($tmpDir) { Write-Host "临时目录: $tmpDir" -ForegroundColor Cyan }
Write-Host ""

$okCount = 0
foreach ($r in $repos) {
    $target = Join-Path $root $r.name
    if (Test-Path (Join-Path $target ".git")) {
        Write-Host "[SKIP] $($r.name) 已存在" -ForegroundColor Yellow
        $okCount++
        continue
    }
    # 清掉残留的半成品目录（没有 .git 的）
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }

    Write-Host "[CLONE] $($r.name) ..." -ForegroundColor Green
    $cloneUrl = Wrap-Url $r.url
    # native command（git）的 stderr 默认不会触发 PS 异常，这里显式 2>&1 让进度/错误都可见
    & git clone --depth 1 $cloneUrl $target 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $target ".git"))) {
        Write-Host "  OK" -ForegroundColor Green
        $okCount++
        continue
    }

    # git clone 失败 → ZIP 兜底下载
    Write-Host "  git clone 失败 (exit=$LASTEXITCODE)，尝试 ZIP 下载..." -ForegroundColor Yellow
    $ownerRepo = $r.url -replace '^https://github.com/', '' -replace '\.git$', ''
    $cleaned = $false

    # 探测默认分支：先试 API，再退回常见分支名
    $branches = @()
    $default = Get-DefaultBranch $ownerRepo
    if ($default) { $branches += $default }
    $branches += @("master", "main") | Where-Object { $_ -ne $default }

    foreach ($b in $branches) {
        $zipUrl = Wrap-Url "https://github.com/$ownerRepo/archive/refs/heads/$b.zip"
        $zipPath = Join-Path $root "$($r.name).zip"
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
            Expand-Archive -Path $zipPath -DestinationPath $root -Force
            Remove-Item $zipPath -Force
            # GitHub ZIP 解压后会有一层 "<repo>-<branch>" 子目录，精确匹配并重命名
            # 只匹配本次 repo 对应的子目录，取第一个，避免和其他 repo 混淆
            $expectedPrefix = "$($r.name)-"
            $extracted = Get-ChildItem -Path $root -Directory |
                Where-Object { $_.Name -like "$expectedPrefix*" } |
                Select-Object -First 1
            if ($extracted) {
                if (Test-Path $target) { Remove-Item -Recurse -Force $target }
                Rename-Item -Path $extracted.FullName -NewName $r.name
                Write-Host "  OK (via ZIP, branch=$b)" -ForegroundColor Green
                $okCount++
                $cleaned = $true
                break
            }
        } catch {
            Write-Host "  ZIP (branch=$b) 失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        }
    }

    if (-not $cleaned) {
        Write-Host "  [FAIL] $($r.name) 所有方式都失败" -ForegroundColor Red
        Write-Host "  请手动下载: $($r.url -replace '\.git$', '')" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "完成（$okCount / $($repos.Count)）。external/ 目录内容：" -ForegroundColor Cyan
Get-ChildItem -Path $root -Directory | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host ""
Write-Host "提示：external/ 已在 .gitignore 中排除，不会污染 Git 历史。" -ForegroundColor Gray
