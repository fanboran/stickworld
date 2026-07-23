# building_gen：程序化建筑生成系统

> 本模块负责程序化生成建筑实体及其材质：
> - `buildings/` + `scenes/` + `scripts/preview/`：建筑零件装配、编辑器预览、建筑定义（核心）
> - `materials/`：每种材质独立开发、独立迭代，共享底层 Shader 原语与截图工具链
>
> 茅草材质的专属迭代日志见 [materials/thatch/README.md](file:///f:/VSCode/game-2/stick-world/modules/building_gen/materials/thatch/README.md)。

---

## 目录结构

```
modules/building_gen/
├── api.gd                          # 模块对外 API（预留）
├── README.md                       # 本文件：系统级说明
├── buildings/                      # 程序化建筑定义（核心）
│   ├── pg_smithy_lv1.gd            #   铁匠铺 Lv1 生成脚本（继承 Building 基类）
│   └── pg_smithy_lv1.tscn          #   铁匠铺 Lv1 场景（碰撞/交互区/工作槽位）
├── scenes/                         # 建筑编辑/预览场景（核心）
│   ├── smithy_reference.tscn       #   铁匠铺完整参考场景（程序化零件装配）
│   └── smithy_preview.tscn         #   铁匠铺编辑器实时预览场景
├── materials/                      # 材质配方，每种材质一个子目录
│   ├── thatch/                     # 茅草屋顶（已实现）
│   │   ├── shaders/thatch.gdshader
│   │   ├── scripts/debug/thatch_debug.gd
│   │   ├── scripts/debug/thatch_building_demo.gd
│   │   ├── scenes/thatch_debug.tscn
│   │   ├── scenes/thatch_building_demo.tscn
│   │   └── reference/              # 参考图与截图
│   ├── stone_wall/                 # 浅色石墙（已实现）
│   │   ├── shaders/stone_wall.gdshader
│   │   ├── scripts/debug/stone_wall_debug.gd
│   │   ├── scenes/stone_wall_debug.tscn
│   │   └── reference/              # 参考图与截图
│   ├── stone_band/                 # 蓝灰石檐（已实现）
│   │   ├── shaders/stone_band.gdshader
│   │   ├── scripts/debug/stone_band_debug.gd
│   │   ├── scenes/stone_band_debug.tscn
│   │   └── reference/              # 参考图与截图
│   ├── stone_window/               # 拱形石窗（已实现）
│   │   ├── shaders/stone_window.gdshader
│   │   ├── scripts/debug/stone_window_debug.gd
│   │   ├── scenes/stone_window_debug.tscn
│   │   └── reference/              # 参考图与截图
│   └── wood/                       # 木板墙（待实现）
├── scripts/
│   ├── preview/                    # @tool 预览脚本（编辑器实时渲染）
│   │   ├── smithy_reference.gd     #   装配铁匠铺所有零件到场景
│   │   └── smithy_preview.gd       #   编辑器内实时预览
│   ├── materials/
│   │   └── procedural_materials.gd # 程序化材质（CPU 合成贴图，遗留方案）
│   └── debug/
│       └── capture_in_game.gd      # 通用：标准运行模式自动截图
├── shaders/
│   └── lib/
│       ├── hash.gdshaderinc        # 共享：确定性 hash 原语
│       └── stone_lib.gdshaderinc   # 共享：石头 SDF / 笔触 / 配色原语
├── tools/
│   ├── capture_standard.ps1        # 通用截图 wrapper（支持 -Material）
│   └── capture_movie.ps1           # Movie Maker 备选方案
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

### 运行测试

```powershell
godot --headless --path stick-world res://tests/modules/building_gen/test_thatch_shader.tscn
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

## 迁移记录

本次架构迁移将旧版 "Python+OpenCV+GDScript CPU 合成贴图" 方案，切换为 "Godot Shader 实时渲染" 方案。

### 旧文件去向

| 原位置 | 去向 | 说明 |
|--------|------|------|
| `modules/building_gen/tools/capture_debug.gd` 等 7 个 GDScript 工具 | `prototypes/building_gen_legacy/tools/gdscript_archive/` | 旧版截图/渲染脚本 |
| `modules/building_gen/tools/py/` | `prototypes/building_gen_legacy/tools/py/` | 旧版 Python 材质生成工具链 |
| `modules/building_gen/materials/thatch/shaders/thatch_edge.gdshader` | `prototypes/building_gen_legacy/shaders/` | 旧版 "零后处理" Shader 实验 |
| `modules/building_gen/materials/thatch/reference/thatch_movie_frame*.png` | `prototypes/building_gen_legacy/reference/thatch_movie_frames/` | Movie Maker 实验临时帧 |

### 迁回核心文件（2026-07 修正）

> 此前曾误将下列建筑生成系统的核心文件归档到 `prototypes/building_gen_legacy/`。
> 经确认：`smithy_reference.tscn` / `smithy_preview.tscn` 及其 `@tool` 脚本、`pg_smithy_lv1.*`、`procedural_materials.gd` 才是整个建筑生成系统的核心，并非只是材质生成。现已全部迁回 `modules/building_gen/`，相关 `ext_resource` / `preload` 路径已同步修正。

| 文件 | 当前位置 | 作用 |
|------|----------|------|
| `pg_smithy_lv1.gd` / `.tscn` | `modules/building_gen/buildings/` | 铁匠铺 Lv1 程序化建筑定义 |
| `smithy_reference.tscn` | `modules/building_gen/scenes/` | 完整建筑零件装配参考场景 |
| `smithy_preview.tscn` | `modules/building_gen/scenes/` | 编辑器实时预览场景 |
| `smithy_reference.gd` / `smithy_preview.gd` | `modules/building_gen/scripts/preview/` | `@tool` 装配/预览脚本 |
| `procedural_materials.gd` | `modules/building_gen/scripts/materials/` | CPU 合成贴图（茅草/木材/石材等原语） |

### 清理内容

- 删除 `materials/thatch/reference/` 下所有孤立的 `.import` 文件（源 PNG 已不存在）
- 删除 Movie Maker 临时产生的 `.wav`、`.avi` 和 `.png` 序列

### 保留文件

- `capture_standard.ps1`：标准运行模式截图 wrapper
- `capture_movie.ps1`：Movie Maker 备选方案
- `scripts/debug/capture_in_game.gd`：场景内自动截图脚本

---

## 版本控制

### 不应提交的文件

下列文件由工具自动生成，已写入 [`stick-world/.gitignore`](file:///f:/VSCode/game-2/stick-world/.gitignore)，**不要提交**：

| 文件类型 | 示例 | 说明 |
|----------|------|------|
| 自动截图 | `materials/<name>/reference/<name>_debug_capture.png` | 每次运行 `capture_standard.ps1` 都会重新生成 |
| 诊断图 | `materials/<name>/reference/diagnose_*.png` | 调试过程中临时保存的诊断画面 |
| 色板图 | `materials/<name>/reference/*_swatch.png` | 由 OpenCV / Shader 自动生成的调色板预览 |
| Movie Maker 临时帧 | `prototypes/building_gen_legacy/reference/thatch_movie_frames/*.png` | Movie Maker 实验产生的 PNG 序列 |
| Godot 缓存 | `.godot/` | 由父级 `.gitignore` 统一忽略 |
| `.uid` 文件 | `*.uid` | 由父级 `.gitignore` 统一忽略 |

### 应提交的文件

- 源代码：`.gd`、`.gdshader`、`.gdshaderinc`、`.tscn`、`.ps1`
- 文档：`.md`
- 手动维护的参考原图：如 `materials/thatch/reference/thatch_ref.png`、`materials/thatch/reference/smithy_lv1_full.png`

新增材质时，若需要保留参考图，请将其命名成非 `*_capture.png` / `diagnose_*.png` / `*_swatch.png` 的形式，避免被 gitignore 误忽略。

## 设计文档

系统级设计规范见：
[docs/技术/教程/程序化材质系统.md](file:///f:/VSCode/game-2/docs/技术/教程/程序化材质系统.md)
