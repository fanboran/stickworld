# config/strategic_map/ — 战略图运行时数据

本目录是战略图（`modules/world_map/`）的运行时数据包，由 `tools/worldgen/` 管线生成并随包发布。

> 数据流与生成端↔消费端契约见 `docs/技术/架构/世界地图数据流.md`。

## 三级数据

| 层级 | 文件 | 内容 | 生成脚本 |
|------|------|------|---------|
| **L3 大世界** | `l3_world.json` + `l3_partition_2048.png` | 大陆级：8192 共享网格多边形 + 2048 索引图（hover/点击查询） | `l2_export/export_l3_view.py` |
| **L2 地区** | `l2_packs/region_XXX/l2_world.json` + `l2_geom.bin` + `l2_tiles_index.png` | 地区级：8192 多边形 + **烘焙 mesh（.bin）** + 索引图 | `l2_export/export_l2_view_packs.py` |
| **L1 地块** | `l1_world.json`（出生）+ `l1_packs/l1_%03d/`（全部 69 老老 L1，结构同出生份）+ 各自 `l1_base.png`/`l1_mask.png` | 地块级：城市多边形 + 聚落 + roads 道路折线 + 邻居/湖泊 | `l1/export_l1_view_context.py`（ roads 由 `l1/road_generate.py` 回写） |

## 道路数据（E1）

- 各 `l1_world.json` 的 `roads`：`{from, to, tier, length_px, polyline[]}`——tier 为 `DIRT`（土路）/`PAVED`（官道，T3+ 重镇间）；polyline 为该包 context 本地坐标 `[x,y]`，端点与聚落 `position_px` 精确对齐。群岛跨海 MST 边无陆路，保留 `{from,to}` 直线（运行时回退直线连线，语义 = 不可达）。
- `roads_global.json`：全大陆路网（8192 全局坐标，含跨 L1 边），E3 快速旅行连通性 / E4 道路场景的数据源。
- 生成：`python tools/worldgen/l1/road_generate.py`（参数外置 `l1/road_params.json`；预览 `tools/worldgen/output/roads_preview_2048.png`）。**改 json 后须重跑 `l_world_bake.gd` 刷 bin**。

## L2 烘焙产物（.bin）

`l2_geom.bin` 是**运行时零几何计算**的关键：earcut 三角剖分 + 描边同源生成在素材阶段由 `l2_bake.py` 完成，运行时直接组装 ArrayMesh。

- 填充三角剖分与描边共用**同一份金标准多边形**（Hausdorff = 0.0px，无补丁感）
- 形状处理：Chaikin×3 平滑像素台阶（保留 ≥3px 真实尖角）+ DP(tol=0.2) 降顶点
- 参考实现：`l2_export/mesh_extract.py`、`l2_export/l2_bake.py`、`l2_export/earclip.py`

## 重生成方式

```powershell
cd tools/worldgen
python l3/fractal_continent.py        # 仅当重建大陆
python l3/region_split.py             # 仅当重划地区
python l2_export/export_l2_packs.py   # L2 图包素材
python l2_export/export_l2_view_packs.py   # → 本目录 l2_packs/（含 .bin）
python l2_export/export_l3_view.py    # → 本目录 L3 素材
```

> 全量导出会重新烘焙全部 13 地区（约 8 min）。历史候选图已移出 git（备份在 `tools/worldgen/_backup/`）。

## 其他

- `color_map.json`：索引图颜色 → label 映射
- `buildings/`：L1 定居点建筑数据（独立于世界生成）
