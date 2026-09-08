# L1 城镇生成管线（tools/worldgen/l1）

种子驱动的 L1 聚落场景生成器：`city_profiles.json`（配置层）+ `city_layout.py`
（布局骨架规划器）+ `city_decor.py`（装饰层规划器）+ `settlement_mapgen.py`
（.tscn 渲染与产物回填）。产物：`stick-world/modules/world/scenes/maps/l1_settlement_00..07.tscn`
与 `stick-world/config/strategic_map/buildings/l1_settlement_XX.json`（初始建筑）。

验收截图工具：`stick-world/tools/worldgen/l1/town_snapshot.gd`（全景/城门近景/地面特写）。

## 装饰层（批次 3）层级契约

场景内绘制序自下而上（z 序唯一真相源 `core/constants/world_z.gd`，容器 z 由
`MapBase._ready` 统一应用；分带/装饰是 TerrainLayer/DecorationLayer 的静态子节点，
不携带脚本、无碰撞）：

| 层 | 载体 | z | 内容 |
|---|---|---|---|
| 草地底 | TerrainLayer/GroundPolygon | 0 | 草地贴图（运行时 apply_grass_texture 上 shader） |
| 地面分带 | TerrainLayer/GroundTurf·GroundRoad·GroundPlazaN·GroundFarmland | 0 | `modules/world/shaders/ground_band.gdshader` 四风格（草皮/土路/石板/农田），矩形边缘 fbm 羽化 |
| 装饰物件 | DecorationLayer/* | 1 | 路灯/树丛/灌木/杂物（木桶·货箱·干草堆），纯 Polygon2D 组，基点在建筑基线（ground_y+96）之前缘草带 |
| 建筑 | BuildingHost / TerrainBuildings | 2 | y-sort，初始建筑运行时从 JSON spawn |
| 单位 | EntityHost | 3 | y-sort |

- 分带与装饰恒在建筑/单位之下：不遮挡建筑外观、不参与单位交互（无碰撞体），
  小地图（只扫 BuildingHost/TerrainBuildings）与资源点存档（只认 ScriptResourceNode）不受污染。
- 草皮带覆盖城内全部硬地皮（两侧 30px 羽化进墙带硬地），土路带=主街踩踏带
  （full 宽 × road_h），石板带=市场净空区全深，农田带=最宽无建筑间隙（profile 开关）。
- 装饰净空：校场带（reserve_band）内零装饰；树冠投影不入建筑 footprint；
  石板带只落在市场净空区（`city_decor.verify_decor` 规划期 assert）。
- 确定性：装饰用独立 rng 流（seed 掺盐），布局 rng 序未被触动——重生成时
  建筑 JSON 逐字节不变，装饰随 seed 变化。
- 性能量级：每城装饰物件 22~50 组（约 90~200 个 Polygon2D 节点，矿区/军镇
  刻意荒凉疏朗、商城密集），无逐草绘制。

## 分城风格（批次 4）

一城一 profile，三轴拉开（差异在氛围不在画风，同属 L1 文化圈）：

| 轴 | profile 字段 | 说明 |
|---|---|---|
| 分带构成 | `density` / `decor.road_h` / landmarks 里 market 条目 dict 形式 `plaza` 覆盖 / `decor.farmland`（true=1 块、int n=最多 n 块，落位受 ≥560px 无建筑间隙约束） | 民居密度 / 土路宽窄 / 石板广场大小 / 田块数 |
| 装饰密度 | `decor.lamp_count·lamp_spacing·trees·bushes·clutter_market·clutter_warehouse·clutter_mix` | `clutter_mix`=[barrel,crate,hay] 权重（渔村偏桶、矿堡偏箱、粮集偏草垛） |
| 时段/色调 | `tone`（默认 noon） | 引用 `city_decor.TONES` 五档：noon 正午 / dawn 清晨冷青 / gold 午后暖金 / dusk 黄昏粉橙 / overcast 阴雾铁灰；渲染端统一乘 PALETTE 取色烘进 tscn（分带 shader uniform + 装饰颜色），零运行时开销、不换皮不换 shader；天空与昼夜循环是全局系统，不逐城调 |

八城逐城配比与依据见 `city_profiles.json`（AI 提案·待定）。城墙带逐 cell
落位（城墙 def 外观为单 cell 宽定宽体，多 cell 段落位会出幽灵矩形碎片）。

## 重生成流程

```
python tools/worldgen/l1/settlement_mapgen.py            # 默认目录 + 回填 l1_world.json
godot --headless --path stick-world --import             # 首跑连两遍
godot --headless --path stick-world --script res://tools/worldgen/l_world_bake.gd
bash stick-world/tools/check_godot_errors.sh && bash stick-world/tests/run_all.sh
```

## 配置口子（city_profiles.json）

- `defaults.decor`：装饰基准参数（road_h/lamp_count/lamp_spacing/trees/bushes/
  clutter_market/clutter_warehouse/clutter_mix/farmland），每城 `decor` 字段可单项覆盖。
- `tone`（defaults 或每城）：分城时段/色调档，见上表；档位表在 `city_decor.TONES`。
- 地标规格（宽度/净空）在 `city_layout.py LANDMARK_SPECS`，profile 的 landmarks
  条目可用 dict 形式覆盖 width/plaza。
- 配色统一在 `city_decor.PALETTE`（L1 同一文化圈，城间差异来自配比与 tone
  轻量偏移，不换皮）。
