# worldgen/ — 世界地图程序化生成管线

仓库根的 Python 工具链（**非** stick-world 内），负责从空大陆蒙版到游戏可用的战略图数据（L3 大陆 / L2 地区 / L1 地块）。

> 生成端 ↔ 消费端契约见 `docs/技术/架构/世界与战略图/世界地图数据流.md`；算法细节见 `docs/设计/系统/08-程序化世界生成.md`；全部工具清单见 `docs/技术/编辑器工具索引.md` §worldgen。

## 目录结构（按生成阶段拆分）

```
tools/worldgen/
├── README.md              # 本文档
├── requirements.txt       # Python 依赖
├── .gitignore             # 忽略 _backup/ 备份与中间产物
├── l3/                    # L3 大陆生成 + 群系 + 地形着色 + 地区划分 + 世界重生成 V2 链（活跃）
│   ├── fractal_continent.py        # 分形大陆（8K 高度场 + 河流）
│   ├── biome_generate.py           # 群系生成（Whittaker 温湿矩阵 → biome_labels_2048.npy + 炎热大陆热区）
│   ├── biome_params.json           # 群系参数（温度/降水/干旱带/雨影/热区，全外置可调）
│   ├── terrain_render.py           # 程序着色地形底图（l3_terrain.png + L2 每地区裁切，--install 入 config）
│   ├── terrain_params.json         # 着色参数（hillshade/明度/岩石雪线/海洋渐变/海岸线/热区暖调）
│   ├── region_split.py             # 地区划分（watershed 沿地形切分）
│   ├── region_preview_annotated.py # 地区标注预览
│   ├── state_expand_lite.py        # 政权简化版（P7：文化圈锚点 flood-fill + 都城扩张 → political_data.json + 政权底图，--dry-run 免写）
│   ├── state_params.json           # 政权参数（V2 链共用：fields_v2 / settlements / states_v2 全段外置可调）
│   ├── fields_common.py            # V2 公共件（路径常量 / 2048 场读取 / FBM / 预览 colormap）
│   ├── fields_build.py             # A1 场（宜居度/资源/进攻成本 → fields/*.npy + 场预览）
│   ├── culture_build.py            # A2 文化场（源点 flood → culture_field/mix + culture_preview）
│   ├── settlement_build.py         # A3 聚落（变半径泊松 → settlements_v2.json + 密度预览）
│   ├── origin_seed_recover.py      # 原地块质心复种（落灰区的原址优先成点；纯抗衡下通常 0 个，存量 6 点在 settlements_v2.json）
│   ├── landmass_util.py            # 同陆块约束（4 连通陆块 / 最近陆地传播 / 同陆块回填 / 一城块一陆块收尾）
│   ├── refine_city_labels.py       # 城块边界 fBm 域扭曲细化（--write；同陆块回填 + 跨块收尾）
│   ├── city_preview_from_refined.py# 城块终图（refined 场渲染，locked 海岸线口径 + 灰统计）
│   ├── settle_preview_v2.py        # 聚落撒点图终版（settlements_preview_locations_2048.png）
│   ├── state_build_v2.py           # A4/A6 政权（划分 + 加速史 + 命名 → political_data_v2 + 政治图/规模谱）
│   ├── arc_topology.py             # 共享弧拓扑重建（arcs 预览；城块变更后须重跑）
│   └── bake_political_v2.py        # 政治数据注入（l3_city 双层 + political_data + --l2 包侧）
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
│   ├── city_split_v3.py           # V2 聚落表重切城块（纯 EDT 最近聚落抗衡，无缝无灰；同陆块并缝 + 一城块一陆块收尾）
│   ├── export_l1_view_context.py  # 出生老 L1 视图上下文导出（Tab 数据源，8192 级；--panorama 出世界全景 preview，F8 缩略窗候选底图）
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

## 世界重生成 V2 链与验收图管线

> V2 = 在既有大陆/群系/地区之上重做「场 → 文化 → 聚落 → 城块 → 政权」。定稿模型与进度见 `docs/项目/交接/世界模型整合-进度与交接.md` §五；本节是**操作手册**：每一步敲什么、吃什么、产什么、验收图从哪来。

### 阶段流（自上而下，上游产物是下游输入）

```
fractal_continent / biome_generate / region_split（旧链：大陆/群系/13 地区）
  └─ l3/fields_build.py     A1 场 → output/fields/{suitability,mineral,fertile,forest,fishsalt,attack_cost}.npy
                            + fields_preview_{suitability,resources,attack_cost}_2048.png
     └─ l3/culture_build.py A2 文化 → culture_field/culture_mix.npy + culture_preview_2048.png
        └─ l3/settlement_build.py  A3 聚落 → settlements_v2.json（1036 正常聚落 + 6 原址复种点，坐标 8192 级）
                                   + settlements_preview_density_2048.png
           └─ l1/city_split_v3.py  城块 = 纯「最近聚落抗衡」（EDT，每寸陆地都有归属、无缝无灰）
              └─ l3/state_build_v2.py  A4/A6 政权 → political_data_v2.json
                                        + states_v2_preview_{political,spectrum}_2048.png
```

### 城块划分 + 终图（定稿操作序列）

```bash
PY=py -3.12   # PATH 里 Inkscape 自带 python 无 scipy，必须用 py -3.12

# ① 全量划分（纯 EDT 最近聚落抗衡 / 同陆块并缝 / 一城块一陆块收尾 / mesh / 配色 / JSON）
$PY l1/city_split_v3.py --cached-parent
#    → city_labels_8192.npy + city_data.json + city_partition/city_cities_8192.png

# ② 边界细化（fBm 域扭曲 + 同陆块回填 + 跨陆块收尾）
$PY l3/refine_city_labels.py --write
#    → refined_city_labels_8192.npy + output/refine_preview_{海岸段,内陆界}.png

# ③ 终图与政权
$PY l3/city_preview_from_refined.py   # city_preview_8192.png（locked 海岸线口径，附灰区统计）
$PY l3/settle_preview_v2.py           # settlements_preview_locations_2048.png（撒点 + 灰点）
$PY l3/state_build_v2.py              # 政权 + states_v2_preview_{political,spectrum}_2048.png

# ④ blob 验收图（现行 R5 场叠加管线——与游戏内 Tab 城区图同源；只出预览不写游戏包）
$PY l1/blob_v2_generate.py            # blob_v2_preview_2048.png + blob_v2_closeup.png
```

### 验收图 → 生成管线速查

> 验收目录：`F:\VSCode\game-2\temp\v2_rebake\`——各图由下述脚本产到 `output/` 后复制过去；**逐图讲解（嵌图+看点）见 [docs/images/v2_rebake/README.md](../../docs/images/v2_rebake/README.md)**。

| 验收图 | 生成脚本 | 关键输入 |
|---|---|---|
| fields_preview_{suitability,resources,attack_cost}_2048 | `l3/fields_build.py` | 8K 高程 / 群系 / 河湖 → 场 npy |
| culture_preview_2048 | `l3/culture_build.py` | A1 场 + 群系 |
| settlements_preview_density_2048 | `l3/settlement_build.py` | settlements_v2.json |
| settlements_preview_locations_2048 | `l3/settle_preview_v2.py`（终版，覆盖 settlement_build 的初版） | settlements_v2.json + suitability + biome_labels_2048 |
| city_preview_8192（终图） | `l3/city_preview_from_refined.py` | refined_city_labels_8192.npy + city_data.json 配色 + locked 海岸线 |
| city_partition_8192 / city_cities_8192 | `l1/city_split_v3.py`（步骤⑤内建预览） | city_labels（未细化） |
| refine_preview_海岸段 / 内陆界 | `l3/refine_city_labels.py`（自带对比预览） | 旧 labels vs refined 并排 |
| states_v2_preview_political_2048 / spectrum | `l3/state_build_v2.py`（`--skip-preview` 可关） | political_data_v2 + refined 场 + 聚落表 |
| river_vectors_preview | `l2_export/river_export.py` | locked 河流 |
| roads_preview_2048 | `l1/road_generate.py` | 聚落表 + 地形 |
| blob_v2_preview_2048 / blob_v2_closeup | `l1/blob_v2_generate.py`（现行 R5 场叠加管线，产三档烘焙源几何 npz；尺寸/分档参数统一在 `l1/blob_v2_params.json`：R=r0_px+r1_px·ps 零截距终态 r0=0/r1=30、三档 ps=0.18/0.5/0.82；submodule 根 `blob_params.json` 是退役径向代的旧档，v2 不读） | settlements_v2 + 城块多边形 + 地形场 |

- `l3/arc_topology.py`（共享弧拓扑 → political_mesh）：**管线自检工具，不出验收图**——城块几何定稿收线时 `--write` 落地，指标（弧配对率/面积守恒）进交接档。

- 城块几何更新后（city_labels / refined 变更），arcs、包内道路、political mask 等下游按交接档 §五剩余工作清单重跑；本表只列预览图的直接生成器。
- `l3/tile_world_*.py`（属性层试验线）已废弃，勿再运行。

## Demo 工作量展示素材

创始人指示：以下预览图作为对外 Demo 展示的工作量佐证（已 gitignore 白名单入库，路径相对 `tools/worldgen/output/`）：

| 文件 | 内容 |
|------|------|
| `l3_terrain.png` | 全大陆程序着色地形图（2048²）：七群系 + hillshade 山体阴影 + 河湖海渐变 + 炎热大陆暖调 |
| `l2_preview_region_008.png` | 炎热大陆（region_008）特写预览（1600² 缩版） |
| `l2_preview_region_013.png` | 出生地区（region_013）特写预览（1600² 缩版） |
| `smooth_closeup_*.png` | R3 地块边缘平滑特写对比（同窗四联：旧整数台阶 4x/12x vs 新亚像素等值线 4x/12x；出生包 + 批量包样例） |

> 重生成：`python l3/terrain_render.py --install` 出全量底图后，用 PIL 对地区裁切 `thumbnail((1600,1600))` 重出缩版（命名保持 `l2_preview_region_XXX.png` 以命中 gitignore 白名单）。

## 运行注意

- **Python 解释器**：用 `py -3.12`（PATH 里 Inkscape 自带的 python 没有 scipy，直接敲 `python` 会 `ModuleNotFoundError`）。
- **工作目录**：在 `tools/worldgen/` 根目录运行脚本（部分脚本用 `HERE` 定位 `output/`，已在子目录脚本中用「双 dirname 回退根目录」处理）。
- **依赖**：`pip install -r requirements.txt`（numpy / PIL / scipy / scikit-image）。
- **产物同步**：`export_*` 会把运行时素材拷到 `stick-world/config/strategic_map/`，随包发布。
- **历史候选图**：`output/archive/` 已移出 git（3.1 GB），备份在 `_backup/archive/`，勿再入库。

## 归档说明

- `archive/`：地区合并 / 画线切口 HTML 工具 + 应用脚本、地块标记 / 切分工具——一次性人工调整，已定稿不再运行。
- `legacy/`：早期分形生成链（`generate.py` 入口），已被 `fractal_continent.py` 取代，仅当需要复现旧算法时使用。
