# world_map：战略图（鸟瞰世界地图，玩家不在其中）

> 三级视图：L1 聚落图（Tab 键）/ L3 大世界（M 键）/ L2 地区详图（L3 单击地区下钻）。
> 与「场景图」（玩家所在的卷轴地图，modules/world）是两类地图概念，术语区分见
> [docs/技术/架构/世界地图数据流.md](docs/技术/架构/世界地图数据流.md) §一。
>
> 架构设计与数据模型见 [docs/技术/架构/战略图架构.md](docs/技术/架构/战略图架构.md)；
> 程序化产物 → 本模块的消费契约见 [docs/技术/架构/世界地图数据流.md](docs/技术/架构/世界地图数据流.md)。

---

## 目录结构

```
modules/world_map/
├── api.gd                           # 对外契约（详见下节「对外契约」）
├── data/                            # 纯数据容器（RefCounted/Resource，无节点逻辑）
│   ├── l1_world_data.gd             # L1WorldData：出生 L1 世界数据（8 城邦；底图/索引图/道路/聚落）
│   ├── l1_tile_def.gd               # L1TileDef：1 个 L1 地块 = 1 个聚落（多边形 + 聚落引用）
│   ├── settlement_ref.gd            # SettlementRef：聚落轻量引用（map_id/population_score，不存场景图内部）
│   ├── resource_deposit.gd          # ResourceDeposit：地块内资源点
│   ├── road_segment.gd              # RoadSegment：聚落间道路段
│   ├── travel_planner.gd            # TravelPlanner：路网 Dijkstra（快速/步行旅行共用，带阻断过滤）
│   ├── l3_world_data.gd             # L3WorldData：大世界 13 个 L2 地区分块（索引图 + 政权 mask/mesh + states 表）
│   ├── l2_world_data.gd             # L2WorldData：地区视图包（底图/地块索引图，label 与 L3 独立命名空间）
│   └── political_lut.gd             # PoliticalLut：政权色 256x1 LUT（运行时查表上色，改表即换色零重烘）
├── scripts/
│   ├── strategic_map_controller.gd  # StrategicMapController：L1 主控制器（Tab；单击选中/双击进城/ESC 关）
│   ├── map_renderer.gd              # MapRenderer：L1 渲染（地形/政治/交通三模式 + hover/选中/建成区 blob）
│   ├── l3_map_controller.gd         # L3MapController：大世界控制器（M；单击地区下钻 L2，关闭保留视图状态）
│   ├── l3_map_renderer.gd           # L3MapRenderer：大世界渲染（MODE_L1/MODE_CITY 双显示模式 + 三级界线 + 所在地区流光）
│   ├── l2_map_controller.gd         # L2MapController：地区详图控制器（ESC 回 L3；点击 L1 地块开 Tab 图）
│   ├── l2_map_renderer.gd           # L2MapRenderer：地区渲染（恒城市模式纯矢量 + 相邻地区上下文）
│   ├── map_camera.gd                # MapCamera：拖拽/滚轮缩放/边界约束/视口限位（三视图共用，常驻）
│   ├── map_mode_manager.gd          # MapModeManager：地图模式全局节点（TERRAIN/POLITICAL/TRAFFIC，跨视图广播）
│   ├── map_controller_util.gd       # MapControllerUtil：三级控制器共用的组件自探测原语
│   ├── map_label_layer.gd           # MapLabelLayer：三级标注（国名/地区名/城市）+ 都城标记（按屏幕像素光栅化）
│   ├── map_mesh_builder.gd          # MapMeshBuilder：政治矢量 fill 的 ArrayMesh 构建（L2/L3 同源）
│   ├── settlement_blob.gd           # SettlementBlob：建成区三档贴图 + 档位判定（population_score 0.35/0.65 分档）
│   ├── flow_outline.gd              # FlowOutline：蓝光流动描边（"你在这里"标记统一视觉语言）
│   ├── map_sketch.gd                # MapSketch：线条几何工具（无向边去重 edge_key/折线串闭合）
│   ├── map_tokens.gd                # MapTokens：线条/语义色 token 唯一取值处（渲染器内禁止色值/线宽字面量）
│   └── l3_zoom_indicator.gd         # MapHUD：底部 HUD（地图模式条 + 缩放条 + L3 细分按钮，三视图共用组件）
├── ui/
│   ├── granularity_indicator.gd     # GranularityIndicator：当前层级（L1/L2/L3）+ 按键操作提示
│   ├── l1_thumbnail.gd              # L1Thumbnail：顶部小地图区世界缩略窗（Tab 顶部态双窗之一，另一窗 = Minimap）
│   ├── map_title_bar.gd             # MapTitleBar：左上角视图名牌（层级徽标 + 视图名 + 数据概览）
│   ├── map_legend.gd                # MapLegend：右下角图例（数据驱动，切模式换整套条目）
│   ├── settlement_tooltip.gd        # SettlementTooltip：聚落悬停提示
│   ├── travel_dialog.gd             # TravelDialog：双击聚落弹窗 [走过去 | 快速旅行 | 取消]
│   └── map_ocean_backdrop.gd        # MapOceanBackdrop：全屏海洋底（三视图共用，CanvasLayer 首子节点）
├── scenes/
│   ├── strategic_map.tscn           # L1 视图（CanvasLayer layer = LayerOrder.STRATEGIC_L1 = 100）
│   ├── strategic_map_l3.tscn        # L3 视图（STRATEGIC_L3 = 101）
│   └── strategic_map_l2.tscn        # L2 视图（STRATEGIC_L2 = 102）
└── shaders/
    └── political_mask_colorize.gdshader  # 政权 ID mask → LUT 查表逐像素上色
```

## 对外契约（api.gd）

外部模块只能经 `api.gd` 交互，禁止引用模块内部脚本（api 节点位于各场景的 Content 子节点下）。

**本地信号**：
- `settlement_clicked(settlement_id)` —— L1 单击聚落选中（控制器发射）
- `settlement_activated(settlement_id)` / `region_hovered(tile_id, settlement_id)` —— 已声明，当前代码无发射点（双击实际直接走 `enter_settlement` 旅行分流，hover 由渲染器 + SettlementTooltip 内部消化）
- 战略图开/关通知统一走 `EventBus.strategic_map_opened/closed`，本地不重复声明

**方法分组**：
- 初始化/数据：`setup` / `initialize`（出生 L1）/ `open_l1(l1_label)`（下钻老 L1 视图包）/ `ensure_player_l1` / `get_data` / `query_at_screen` / `get_settlement_ref` / `get_tiles` / `get_roads`
- 玩家位置：`set_player_map(map_id)`（场景图反查聚落，命中即记到访 + 更新快速旅行起点）
- 快速旅行：`get_travel_status` → `TRAVEL_*` 状态码（OK/SELF/NO_SCENE/UNVISITED/UNREACHABLE/BLOCKED/BATTLE）+ `fast_travel_to`；语义 = 已到访 ∧ 路网连通 ∧ 未阻断 ∧ 非战斗
- 步行旅行：`get_walk_status` / `walk_to`（不要求已到访——走过去正是解锁到访的手段；组装 `WorldState` 步行队列后发 `EventBus.travel_requested`）
- 进出：`enter_settlement(settlement_id, mode)`（发 `travel_requested` 并关图）/ `close_strategic_map`
- 选中/相机/模式：`select` / `deselect` / `camera_focus` / `screen_to_map` / `map_to_screen` / `set_map_mode` / `get_map_mode`
- 政治（只读）：`get_state_color` / `get_states`

**消费的全局事件**：`EventBus.settlement_updated`（聚落规模刷新 → 当前 L1 单城 blob 重算；L2/L3 为烘焙静态层不重算）、`battle_started/ended`（战斗中禁旅行）、`region_owner_changed`（政治模式染色的数据源，见 EventBus 信号注释）。

## 视图层级与输入

装配方是 `stick-world/modules/world/scripts/setup/system_setup.gd`（L0 依赖方向的例外：world 是唯一 composition root）：按装配步骤表实例化三场景挂 GameRoot，Content 常驻隐藏（instantiate + 数据加载耗时大，借加载屏分帧消化）。

- **L1（Tab，层 100）**：Tab 键在 `stick-world/modules/world/scripts/travel/map_boundary_detector.gd` 监听（发 `open_world_map_requested`），边界自动触发则直接开大图。Tab 三态循环：HIDDEN → TOP_MINIMAPS（顶部双窗：Minimap + L1Thumbnail）→ FULL_L1 大图 → 关。Tab 打开跟随玩家所在 L1（`ensure_player_l1`）。
- **L3（M，层 101）**：M 键由 SystemSetup `_unhandled_input` 全局监听。单击地区下钻 L2；关闭时保留 `_l2_active`，重开直接恢复 L2 视图。
- **L2（下钻，层 102）**：L3 单击地区进入（地区视图包懒加载）；点击 L1 地块经 `api.open_l1` 打开对应老 L1 的 Tab 视图；ESC 逐级 `back_requested` 返回（L2→L3、L1→L2）。
- **M/Tab 互斥**（SystemSetup 裁决）：M 打开 L3 前先关 L1 大图；L3 会话激活期间（L3 可见或 L2 下钻中，`_is_l3_session_active`）Tab/边界触发直接忽略——避免 L1 在 L3 海洋层下被盖住打开、M 一关又意外弹出。
- **相机状态保持**：三视图相机常驻不重建；首次打开做一次初始视角（L1 = 整图适配且记为 100%；L3 = 整图 + 上下 `OCEAN_MARGIN` 海洋带，锁定 min_zoom 并设视口限位），之后保留用户位置/缩放；L3↔L2 下钻往返、M 关重开均不重置。
- **13 地区分块与 hover**：L3 = 13 个 L2 地区分块（`L3WorldData`）；hover/下钻走索引图像素查询（label 直编，P 社 provinces.bmp 机制）——L3 hover 恒命中老 L1 索引图、点击下钻按 L2 索引图；L2 地区常驻描边，玩家所在地区叠加蓝光流动描边（FlowOutline，出生地区 = region_013，含老 L1 #69）。

**与 worldgen 数据的消费关系**：本模块是程序化世界产物的消费端，运行时读 `res://config/strategic_map/` 下的视图包（出生 L1 数据、`l1_packs/` 老 L1 包、`l2_packs/` 地区包、L3 大世界数据，JSON + PNG，由 worldgen 工具产出：L2/L3 视图包在 `tools/worldgen/l2_export/`，建成区 blob 在 `tools/worldgen/l1/`）。产物清单与字段映射见 [docs/技术/架构/世界地图数据流.md](docs/技术/架构/世界地图数据流.md) §二/§六。

## 依赖

- `modules/ui_global/`：`SketchPanel`（HUD 部件基类）、`StickTokens`（交互线/操作线语义色）、`LayerOrder`（战略图三层 CanvasLayer 层号）
- `modules/world/`：`WorldAPI.TravelMode`（旅行模式枚举）；反向：world（SystemSetup）装配并驱动本模块三视图
- core autoload：`EventBus`（travel_requested / strategic_map_opened/closed / settlement_updated / battle_started/ended）、`WorldState`（visited_settlements / 步行旅行队列）

## 扩展指引

- **加一个视图 HUD 部件**（以 L2 为例）：部件脚本放 `ui/`（以 `stick-world/modules/world_map/ui/map_title_bar.gd` 为样板，继承 SketchPanel），场景挂对应 `.tscn` 的 CanvasLayer 直下，控制器（`scripts/l2_map_controller.gd`）的 `open()`/`close()` 同批显隐并喂文案。
- **加线条/颜色**：只改 `stick-world/modules/world_map/scripts/map_tokens.gd` 加 token，渲染器内禁止新增色值/线宽字面量（口径见 map_tokens.gd 头注）。
- **加地图模式**：`scripts/map_mode_manager.gd` 的 Mode 加枚举 + 各渲染器 `set_map_mode` 分支 + `scripts/l3_zoom_indicator.gd`（MapHUD）模式条按钮。
- **改旅行规则**：可达性判定集中在 `api.gd` 的 `get_travel_status`/`get_walk_status`（「已到访/战斗中」等运行时状态都在这）；纯图算法（最短路/阻断）在 `data/travel_planner.gd`。
- **改聚落规模表现**：三档贴图 + 档位阈值在 `scripts/settlement_blob.gd`（`TIER_THRESHOLDS = [0.35, 0.65]`，按运行时扰动后 population_score 分档）；规模变动经 `EventBus.settlement_updated` 到 `api._on_settlement_updated`。
- **加标注**：`scripts/map_label_layer.gd`（挂渲染器父级 Content，自己换算屏幕坐标，字形按真实像素光栅化——勿挂进相机子树）。
