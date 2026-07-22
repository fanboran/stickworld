# 旧版截图/渲染工具归档

本目录存放 `modules/building_gen/tools/` 在架构迁移前的旧版 GDScript 工具。

## 归档原因

新材料系统改为**纯 Shader 实时渲染**（`materials/<name>/shaders/<name>.gdshader`），不再使用 GDScript 在 CPU 端合成贴图，也不再需要 `procedural_materials.gd` 中的贴图生成函数。因此下列工具已失去原有用途，迁移到此处作为历史备份。

## 文件说明

| 文件 | 原用途 |
|------|--------|
| `capture_debug.gd` | 标准运行模式下保存 viewport 截图到 `modules/building_gen/reference/thatch_debug_capture.png` |
| `composite_preview.gd` | CPU 合成 `smithy_preview.tscn` 为 PNG，避开 headless SubViewport 截图问题 |
| `dmp.gd` | 读取 `_material_config.json` 切换材质，调用 `procedural_materials.gd` 生成贴图并 dump |
| `render_preview.gd` | 用 SubViewport 渲染 `smithy_preview.tscn` 为 PNG，含动态替换茅草贴图逻辑 |
| `render_reference.gd` | 直接渲染 `smithy_reference.tscn` 为 PNG，用于对比正确位置 |
| `render_roof_only.gd` | 仅渲染 `smithy_preview.tscn` 的三个屋顶多边形，用于和 `thatch_ref.png` 对比 |
| `render_window.gd` | 用 SubViewport 渲染 `smithy_preview.tscn` 为 PNG（匹配编辑器预览） |

## 新替代方案

- 通用标准运行截图：`modules/building_gen/tools/capture_standard.ps1`
- 场景内自动截图：`modules/building_gen/scripts/debug/capture_in_game.gd`
- Movie Maker 备选：`modules/building_gen/tools/capture_movie.ps1`

## 依赖的旧资源（也已归档/删除）

- `modules/building_gen/scripts/materials/procedural_materials.gd` → 已移除，功能由 Shader 替代
- `modules/building_gen/scenes/smithy_preview.tscn` → 已迁移到 `prototypes/building_gen_legacy/scenes/`
- `modules/building_gen/scenes/smithy_reference.tscn` → 已迁移到 `prototypes/building_gen_legacy/scenes/`
