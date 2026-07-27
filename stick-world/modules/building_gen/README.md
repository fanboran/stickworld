# building_gen：程序化建筑生成系统

> 本模块负责程序化生成建筑实体及其材质：
> - `buildings/` + `scenes/` + `scripts/preview/`：建筑零件装配、编辑器预览、建筑定义（核心）
> - `materials/`：每种材质独立开发、独立迭代，共享底层 Shader 原语与截图工具链
>
> 系统级设计规范见 [docs/技术/教程/程序化材质系统.md](file:///f:/VSCode/game-2/stick-world/docs/技术/教程/程序化材质系统.md)。

---

## 目录结构

```
modules/building_gen/
├── api.gd                          # 模块对外 API（委托 ProceduralMaterials + 建筑实例化）
├── README.md                       # 本文件：系统级说明
├── buildings/                      # 程序化建筑定义（核心）
│   ├── bld_workshop.tscn           #   旧预制场景（construction_manager P0 引用，待新版替换）
│   ├── pg_smithy_lv1.gd            #   铁匠铺 Lv1 生成脚本（继承 Building 基类）
│   ├── pg_smithy_lv1.tscn          #   铁匠铺 Lv1 场景（碰撞/交互区/工作槽位）
│   └── reference/                  #   建筑级参考图与色板
│       ├── smithy_lv1.png ~ smithy_lv4.png
│       ├── smithy_lv1_thatch.png
│       ├── smithy_lv1_thatch_tile.png
│       └── swatches/{白_1,白_2,灰}.png
├── scenes/                         # 建筑编辑/预览场景（核心）
│   ├── smithy_reference.tscn       #   铁匠铺完整参考场景（程序化零件装配）
│   ├── smithy_preview.tscn         #   铁匠铺编辑器实时预览场景
│   └── smithy_reference_textures/  #   smithy 建筑零件纹理（与 smithy_reference.tscn 配套）
├── materials/                      # 材质配方，每种材质一个子目录
│   ├── thatch/                     # 茅草屋顶（已实现）
│   │   ├── shaders/thatch.gdshader
│   │   ├── scripts/debug/{thatch_debug.gd, thatch_building_demo.gd}
│   │   ├── scenes/{thatch_debug.tscn, thatch_building_demo.tscn, smithy_thatch_preview.tscn}
│   │   └── reference/              # 参考图与截图
│   ├── stone_wall/                 # 浅色石墙（已实现）
│   │   ├── shaders/stone_wall.gdshader
│   │   ├── scripts/debug/stone_wall_debug.gd
│   │   ├── scenes/stone_wall_debug.tscn
│   │   └── reference/              # 参考图与截图（含 smithy_lv3.png）
│   ├── stone_band/                 # 蓝灰石檐（已实现）
│   │   ├── shaders/stone_band.gdshader
│   │   ├── scripts/debug/stone_band_debug.gd
│   │   ├── scenes/stone_band_debug.tscn
│   │   └── reference/
│   ├── stone_window/               # 拱形石窗（已实现）
│   │   ├── shaders/stone_window.gdshader
│   │   ├── scripts/debug/stone_window_debug.gd
│   │   ├── scenes/stone_window_debug.tscn
│   │   └── reference/
│   └── wood/                       # 木板墙（待实现，仅 README 占位）
├── scripts/
│   ├── building.gd                 # Building 基类（class_name）
│   ├── building_snap.gd            # 编辑器吸附脚本（@tool）
│   ├── preview/                    # @tool 预览脚本（编辑器实时渲染）
│   │   ├── smithy_reference.gd     #   装配铁匠铺所有零件到场景
│   │   ├── smithy_preview.gd       #   编辑器内实时预览
│   │   └── smithy_thatch_applier.gd#   茅草 ShaderMaterial 应用到 smithy 屋顶
│   ├── materials/
│   │   └── procedural_materials.gd # 程序化材质（CPU 合成贴图，遗留方案，仍被 core API 链引用）
│   └── debug/
│       ├── capture_in_game.gd      # 通用：标准运行模式自动截图
│       └── recrop_references.py    # 一次性 Python 工具（gitignored）
├── shaders/
│   └── lib/
│       ├── hash.gdshaderinc        # 共享：确定性 hash 原语
│       └── stone_lib.gdshaderinc   # 共享：石头 SDF / 笔触 / 配色原语
├── tools/
│   ├── capture_standard.ps1        # 通用截图 wrapper（支持 -Material）
│   ├── capture_movie.ps1           # Movie Maker 备选方案
│   ├── analyze_capture.py          # 一次性 Python 工具（gitignored）
│   ├── extract_embedded_images.py  # 一次性 Python 工具（gitignored）
│   └── inspect_capture.py          # 一次性 Python 工具（gitignored）
└── assets/
    └── white_tex.png               # 4x4 白色纹理，激活 Sprite2D UV
```

---

## 快速开始

### 调试茅草材质

```powershell
# 运行调试场景
& "F:\SteamLibrary\steamapps\common\Godot Engine\Godot_v4.5-stable_mono_win64.exe" `
  --path "F:\VSCode\game-2\stick-world" `
  res://modules/building_gen/materials/thatch/scenes/thatch_debug.tscn

# 自动截图
godot --path stick-world res://modules/building_gen/materials/thatch/scenes/thatch_debug.tscn
# 或使用 wrapper
.\modules\building_gen\tools\capture_standard.ps1 -Material thatch
```

### 调试茅草建筑双屋顶

```powershell
.\modules\building_gen\tools\capture_standard.ps1 `
  -Material thatch `
  -ScenePath "res://modules/building_gen/materials/thatch/scenes/thatch_building_demo.tscn" `
  -OutputFrame "modules/building_gen/materials/thatch/reference/thatch_building_demo_capture.png"
```

### 调试石头材质

```powershell
# 浅色石墙
.\modules\building_gen\tools\capture_standard.ps1 -Material stone_wall

# 蓝灰石檐
.\modules\building_gen\tools\capture_standard.ps1 -Material stone_band

# 拱形石窗
.\modules\building_gen\tools\capture_standard.ps1 -Material stone_window
```

---

## 材质配方契约

每个新增材质应遵循以下约定：

1. **目录命名**：`materials/<name>/`
2. **Shader**：`materials/<name>/shaders/<name>.gdshader`
3. **调试场景**：`materials/<name>/scenes/<name>_debug.tscn`
4. **建筑演示**：`materials/<name>/scenes/<name>_building_demo.tscn`（可选）
5. **参考图**：`materials/<name>/reference/`
6. **截图输出**：`materials/<name>/reference/<name>_debug_capture.png`
7. **关键 uniform**：
   - `resolution`、`bounds`：几何信息
   - `seed`：确定性随机
   - `show_bounds`：调试用边界框
   - 建议提供 `color1` ~ `color5` 调色板

---

## 共享 Shader 原语

`shaders/lib/hash.gdshaderinc` 提供：

- `hash21(vec2 p)`：2D 确定性随机，返回 [0, 1]
- `hash31(vec3 p)`：3D 确定性随机，返回 [0, 1]

用法：

```glsl
#include "res://modules/building_gen/shaders/lib/hash.gdshaderinc"

float h = hash21(p);
```

`shaders/lib/stone_lib.gdshaderinc` 提供石头材质共享原语：

- `sl_sd_rounded_box(vec2 p, vec2 half_size, float r)`：圆角矩形 SDF
- `sl_painterly_edge(vec2 p, float dist, float roughness, float oil_scale, vec2 seed)`：笔触感边缘粗糙化
- `sl_stone_color_blocks(vec2 local, vec3 light, vec3 mid, vec3 dark, vec2 light_dir, float blend)`：三层颜色块采样

用法：

```glsl
#include "res://modules/building_gen/shaders/lib/stone_lib.gdshaderinc"

float dist = sl_sd_rounded_box(brick_local, vec2(bw, bh) * 0.5, corner_radius);
float rough = sl_painterly_edge(p, dist, edge_roughness, oil_scale, hseed);
vec3 col = sl_stone_color_blocks(sample_local, c_light, c_mid, c_dark, light_dir, color_block_blend);
```

---

## 开发注意事项

### Godot 编辑器 mmap 文件锁

Godot 编辑器对 `.tscn` 文件使用内存映射文件（mmap），导致 PowerShell 的 `Set-Content` 或 `[System.IO.File]::WriteAllText` 直接写入会报错。

**绕过方法**：先写入临时文件，再用 `Move-Item` 原地替换：

```powershell
$tmp = "$f.tmp"; $c = [System.IO.File]::ReadAllText($f)
# 编辑 $c ...
[System.IO.File]::WriteAllText($tmp, $c)
Move-Item -Path $tmp -Destination $f -Force
```

### 参考图被 gitignore 误忽略

根目录 `.gitignore` 中 `stick-world/modules/building_gen/**/reference/*` 会把所有 `reference/` 目录下的文件忽略。如果需要在 `buildings/reference/` 下放手动维护的参考图，必须加否定规则：

```gitignore
stick-world/modules/building_gen/**/reference/*
# 但 buildings/reference/ 是手动维护的参考图，需要提交
!stick-world/modules/building_gen/buildings/reference/
!stick-world/modules/building_gen/buildings/reference/**
!stick-world/modules/building_gen/buildings/reference/**/*
```

### Godot 脚本缓存导致旧错误反复出现

`.godot/imported/` 目录缓存了旧版本的 `.gd` 脚本解析结果。如果修改了 `run_tests.gd` 之类文件但 Godot 仍报旧的解析错误，说明缓存未刷新。解决：`--editor --quit` 重导入，或手动删 `.godot/global_script_class_cache.cfg`。

### 根目录与子目录的 .gitignore 关系

`stick-world/.gitignore` 和项目根目录 `.gitignore` 同时生效。`git check-ignore -v <file>` 可以精确定位是哪条规则、哪个文件忽略了目标文件，对排查 gitignore 误匹配非常有用。