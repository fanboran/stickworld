# worldgen/ — 世界地图程序化生成管线

仓库根的 Python 工具链（**非** stick-world 内），负责从空大陆蒙版到游戏可用的战略图数据（L3 大陆 / L2 地区 / L1 地块）。

> 生成端 ↔ 消费端契约见 `docs/技术/架构/世界地图数据流.md`；算法细节见 `docs/设计/系统/08-程序化世界生成.md`；全部工具清单见 `docs/技术/编辑器工具索引.md` §worldgen。

## 目录结构（按生成阶段拆分）

```
tools/worldgen/
├── README.md              # 本文档
├── requirements.txt       # Python 依赖
├── .gitignore             # 忽略 _backup/ 备份与中间产物
├── l3/                    # L3 大陆生成 + 群系 + 地形着色 + 地区划分（活跃）
│   ├── fractal_continent.py        # 分形大陆（8K 高度场 + 河流）
│   ├── biome_generate.py           # 群系生成（Whittaker 温湿矩阵 → biome_labels_2048.npy + 炎热大陆热区）
│   ├── biome_params.json           # 群系参数（温度/降水/干旱带/雨影/热区，全外置可调）
│   ├── terrain_render.py           # 程序着色地形底图（l3_terrain.png + L2 每地区裁切，--install 入 config）
│   ├── terrain_params.json         # 着色参数（hillshade/明度/岩石雪线/海洋渐变/海岸线/热区暖调）
│   ├── region_split.py             # 地区划分（watershed 沿地形切分）
│   └── region_preview_annotated.py # 地区标注预览
├── l2_export/             # L2/L3 网格提取 + 烘焙 + 全部视图导出（活跃，本次核心）
│   ├── mesh_extract.py             # 共享顶点网格提取 + Chaikin 平滑 + DP 降顶点
│   ├── earclip.py                  # 纯 Python 单环耳切剖分
│   ├── l2_bake.py                  # 几何烘焙（剖分 + 描边同源 → .bin）
│   ├── export_l2_packs.py          # L2 图包素材（蒙版/底图/高程/索引图）
│   ├── export_l2_maps.py           # L2 内部 L1 地块分块
│   ├── export_l2_view_packs.py     # L2 运行时视图包（json + 烘焙 .bin）
│   ├── export_l3_view.py           # L3 视图素材
│   ├── export_l1_overview.py       # L1 全图预览
│   └── update_tiles_coastline.py   # 按 8K 蒙版裁切海岸线
├── l1/                    # L1 地块合并 / 生成 / 全大陆 L1 蒙版（活跃）
│   ├── city_split_v2.py           # 老 L1 之下细分城市（13 地区 tiles 拼全局 → 城市蒙版，8192 级，1040 城）
│   ├── export_l1_view_context.py  # 出生老 L1 视图上下文导出（Tab 数据源，8192 级）
│   ├── export_l3_l1_view.py          # L3 视觉层双模式（老 L1 矢量 + 城市贴图 + hover 索引图）
│   ├── export_l2_city_previews.py   # L2 城市模式贴图（每地区 context 尺寸，读 city_preview_8192）
│   ├── merge_tiny_tiles.py
│   ├── merge_tiles_groups.py
│   ├── merge_island_tiles.py
│   └── settlement_mapgen.py        # 预留
├── legacy/                # 早期分形生成链（历史留档，被 generate.py 调用）
│   ├── noise_util.py / landmask.py / mask_utils.py
│   ├── tectonic.py / terrain_template.py / world_map.py
│   ├── commands_map.py / commands_candidates.py / generate.py
├── archive/               # 一次性人工调整工具（HTML 切口/合并 + 脚本）留档
├── experiments/           # 河流算法实验（C/Python）
├── _backup/               # 已移出 git 的历史候选图（本地备份，gitignore）
└── output/                # 生成产物（活跃数据入库，npy 不入库）
    ├── locked/            # 定稿大陆/高度场/河流
    ├── regions/           # 地区划分（labels/元数据/预览）
    ├── l2_packs/          # L2 图包素材（每地区 mask/base/heightmap/tiles）
    ├── l2_view_packs/     # L2 运行时视图包
    ├── l3_view/           # L3 视图素材
    ├── l1/                # 全大陆 L1 蒙版（labels/预览/索引图/元数据）
    └── *.png / *.json     # 顶层预览与中间产物
```

## 数据流顺序

```
fractal_continent.py ──▶ locked/（8K 大陆 + 高度场 + 河流）
   └─▶ region_split.py ──▶ regions/（13 地区 labels/元数据）
        └─▶ export_l2_packs.py ──▶ l2_packs/（每地区素材）
             └─▶ export_l2_maps.py / merge_* / update_tiles_coastline.py ──▶ L1 地块 tiles
                  └─▶ export_l2_view_packs.py ──▶ l2_view_packs/ + config/strategic_map/l2_packs/
                  └─▶ export_l3_view.py ──▶ l3_view/ + config/strategic_map/
biome_generate.py ──▶ output/biome_labels_2048.npy + biome_hot_zone_2048.png（群系/热区）
   └─▶ terrain_render.py --install ──▶ output/l3_terrain.png + l2_packs/*/l2_terrain.png
        ──▶ config/strategic_map/l3_terrain.png + l2_packs/*/l2_terrain.png（游戏内 TERRAIN 模式底图）
```

## Demo 工作量展示素材

创始人指示：以下预览图作为对外 Demo 展示的工作量佐证（已 gitignore 白名单入库，路径相对 `tools/worldgen/output/`）：

| 文件 | 内容 |
|------|------|
| `l3_terrain.png` | 全大陆程序着色地形图（2048²）：七群系 + hillshade 山体阴影 + 河湖海渐变 + 炎热大陆暖调 |
| `l2_preview_region_008.png` | 炎热大陆（region_008）特写预览（1600² 缩版） |
| `l2_preview_region_013.png` | 出生地区（region_013）特写预览（1600² 缩版） |

> 重生成：`python l3/terrain_render.py --install` 出全量底图后，用 PIL 对地区裁切 `thumbnail((1600,1600))` 重出缩版（命名保持 `l2_preview_region_XXX.png` 以命中 gitignore 白名单）。

## 运行注意

- **工作目录**：在 `tools/worldgen/` 根目录运行脚本（部分脚本用 `HERE` 定位 `output/`，已在子目录脚本中用「双 dirname 回退根目录」处理）。
- **依赖**：`pip install -r requirements.txt`（numpy / PIL / scipy / scikit-image）。
- **产物同步**：`export_*` 会把运行时素材拷到 `stick-world/config/strategic_map/`，随包发布。
- **历史候选图**：`output/archive/` 已移出 git（3.1 GB），备份在 `_backup/archive/`，勿再入库。

## 归档说明

- `archive/`：地区合并 / 画线切口 HTML 工具 + 应用脚本、地块标记 / 切分工具——一次性人工调整，已定稿不再运行。
- `legacy/`：早期分形生成链（`generate.py` 入口），已被 `fractal_continent.py` 取代，仅当需要复现旧算法时使用。
