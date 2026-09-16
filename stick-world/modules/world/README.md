# world：场景图组合根 —— 常驻主场景与地图体系

> 本模块是场景图（卷轴地图，玩家在其中）的组合根：
> - `scripts/game_root.gd` + `scenes/game_root.tscn`：常驻主场景（项目入口），装配建造/战斗/组织/资源/背包/附身/战略图等全部跨场景子系统
> - `scripts/map/`：地图宿主（HD-2D 街景 `hd2d_street_map.gd` 及其战场/资源图变体）与布景组件（资源点/城门交互/算法村生成）——旧 2D 村图/道路/守城/2D 天空宿主已于 2026-09-16 随旧 2D 图清退删除
> - `scripts/setup/`：系统装配器、存档、传送、初始内容生成、Demo 目标链
> - 地图场景清单、注册表与切换流程见 [scenes/README.md](scenes/README.md)
>
> 系统级设计见 [docs/技术/架构/场景与战斗架构.md](docs/技术/架构/场景与战斗架构.md)（子篇在 `docs/技术/架构/场景与战斗/`）；
> HD-2D 街景与坐标投影协议见 [docs/技术/架构/建筑管线/HD-2D街景系统.md](docs/技术/架构/建筑管线/HD-2D街景系统.md)。

---

## 目录结构

```
modules/world/
├── api.gd                              # WorldAPI：对外契约（节点路径常量 / MapType / TravelMode / EntrySide）
├── README.md                           # 本文件
├── scenes/                             # 场景（布局唯一真相源）
│   ├── game_root.tscn                  #   主场景：ShortcutGate / EnvironmentSystem / CameraRig / SceneLoader /
│   │                                   #   InputDispatcher / WorldChunkHost / BattleDirector 七常驻节点
│   ├── README.md                       #   地图清单、map_id 注册表、地图切换流程
│   └── maps/                           #   地图场景（HD-2D 主街/资源图/村B/战场/L1 聚落薄实例）
│       └── decorations/                #     tree.tscn / stone.tscn 装饰物子场景
└── scripts/
    ├── game_root.gd                    # GameRoot 组合根：分帧装配 → 注册默认地图与出口 → 加载 START_MAP_ID（hd2d_street）
    │                                   #   快捷键总入口 / ESC 模态栈 / 跨图编队快照；头部有 process_mode 分层表
    ├── game_root_shortcut_gate.gd      # ShortcutGate：暂停期快捷键通道（ALWAYS，仅转发给 handle_shortcuts）
    ├── camera/
    │   └── camera_rig.gd               # CameraRig：1/4 区域跟随 / 边缘滚动 / 滚轮缩放 / 震屏（加载地图时注入边界）
    ├── setup/                          # GameRoot 的脚本化子模块（运行时挂载，各持 setup(root)）
    │   ├── system_setup.gd             #   SystemSetup 装配器：步骤表驱动，装配全部常驻子系统与 UI（37 步）
    │   ├── save_handler.gd             #   SaveHandler：SQLite 存读档全流程（地图/建筑/实体/资源点 → save_meta）
    │   ├── travel_handler.gd           #   TravelHandler：玩家实体查找 + 室内退出检查（大建筑传送链随 mega_interior 图清退拆除）
    │   ├── initial_content.gd          #   InitialContent：村民 NPC（经 TownLifeAPI 配比）/ dev 遭遇战 / 仓库预置
    │   ├── demo_quest.gd               #   DemoQuest：四阶段引导目标链（采集→建造→编队→征伐）+ 结算
    │   └── villager_bubble.gd          #   VillagerBubble：村民头顶对话气泡（DemoQuest 驱动）
    ├── loading/
    │   ├── scene_loader.gd             #   SceneLoader：map_id 注册表 + 出口表 + travel_to_map 统一入口 + EventBus 转发
    │   ├── world_chunk_host.gd         #   WorldChunkHost：当前地图实例挂载点
    │   └── chunk_trigger.gd            #   ChunkTrigger：地图边缘出口触发器（只响应附身实体）
    ├── map/                            # 地图宿主与布景组件
    │   ├── map_base.gd                 #   MapBase 基类：元数据 / spawn_entity / 实体缓存与空间网格 / 视觉域坐标协议
    │   ├── hd2d_street_map.gd          #   Hd2dStreetMap：HD-2D 街景宿主（3D 场景接入 / 角色进 3D / 城门传送带 / 昼夜）
    │   ├── hd2d_battlefield_map.gd     #   Hd2dBattlefieldMap：HD-2D 城郊战场（battlefield 模式变体）
    │   ├── hd2d_resource_map.gd        #   Hd2dResourceMap：HD-2D 城外资源图（西郊/东郊，resource_field 模式）
    │   ├── hd2d_projection.gd          #   Hd2dProjection：俯角投影纯数学（画布域↔视觉域唯一出口，有单测锁死）
    │   ├── hd2d_gate_prompt.gd         #   主街城门选项框（读出口表生成目的地 + 联动舆图；村民走静默传送带）
    │   ├── hd2d_sky_region_map.gd      #   城外舆图（选项框弹出时悬于城外上空，纯展示组件）
    │   ├── city_gen.gd                 #   CityGen：算法村初始城市生成（八档链 / 确定性种子 / 建筑级别窗口）
    │   ├── resource_gen.gd             #   ResourceGen：资源点群落散布 + 林区梯度（HD-2D 图在用）
    │   ├── resource_node.gd            #   ResourceNode：资源点逻辑（储量 / 枯竭 / 重生；视觉由宿主承担）
    │   ├── conquest_anchor.gd          #   ConquestAnchor：敌据点布阵锚点（守军位 / 敌将位 / 集结线）
    ├── placement/
    │   ├── placement_grid.gd           #   PlacementGrid：32px 竖向条带占地网格（选址 / 登记 / 动态扩展）
    │   └── grid_cell.gd                #   GridCell：单条带占用记录
    └── travel/
        └── map_boundary_detector.gd    #   MapBoundaryDetector：边界停留提示 + 请求打开战略图（Tab/M 入口之一）
```

---

## 对外契约

### WorldAPI（api.gd）

- **节点路径常量**：`PATH_*` 两族——GameRoot 常驻子节点（EnvironmentSystem/CameraRig/SceneLoader/InputDispatcher/WorldChunkHost/UIRoot/BattleDirector）与 MapInstance 子节点（PlacementGrid/BuildingHost/EntityHost/ChunkTriggers/BattleAnchor/TerrainBuildings/WalkBarrier/BuildMaskLayer/ForegroundLayer/GroundLine 等）。修改 GameRoot 节点结构须同步本文件。
- **枚举**：`MapType`（VILLAGE/BATTLEFIELD/ROAD/INDOOR/MEGA_INTERIOR）、`TravelMode`（WALK/FAST_TRAVEL/TELEPORT）、`EntrySide`（LEFT/RIGHT）。

### 地图宿主 duck API（MapBase 及子类）

外部对地图实例的全部消费走 duck 方法（`has_method` 防御），由 MapBase 统一供给：
`spawn_entity` / `get_entities`（每物理帧缓存一次）/ `query_neighbors`（空间网格邻域查询）/ `get_possessed_entity` / `get_walk_barriers` / `get_passage_barriers` / 元数据 getter（`ground_y`、`ground_ratio`、`map_left`、`map_right`、`ground_bottom`）。
视觉域坐标协议 `remap_fx_pos` / `unmap_fx_pos` / `entity_hover_rect`：2D 图恒等，HD-2D 图覆写——一切锚定实体位置的画布元素（悬浮框/飘字/粒子/点选判定）必须经此组方法进同一域，禁止手搓投影公式。

### SceneLoader（本地信号 + EventBus 同名转发）

- 信号：`map_loaded(map_id, map_type)`、`map_unloaded(map_id)`、`travel_started(from_id, to_id, mode)`、`travel_completed(to_id)`、`chunk_loaded/chunk_unloaded`（chunk 两项为预留接口，未实现）。
- 方法：`register_map` / `register_map_exit`（同一方向可多条出口）/ `travel_to_map`（步行/快速旅行/传送统一入口）/ `load_map` / `get_current_map` / `get_registered_map_ids` / `get_map_exits`。

### GameRoot 公共方法（UI 与测试消费面）

`get_current_map` / `get_player_entity` / `request_map_travel` / `start_new_game` / `start_test_battle` / `is_in_battle` / `load_game_from_slot` / `quick_save` / `quick_load` / `toggle_save_panel` / `toggle_inventory` / `toggle_stats_panel` / `toggle_formation_panel` / `toggle_org_panel` / `toggle_settings_menu`；`get_combat_api` / `get_construction_api` / `get_organization_api` 等 getter 系列供测试与跨模块消费（正式交互走各模块 api.gd）。

### EventBus 关键发布订阅（本模块侧）

| 方向 | 信号 | 端点 |
|---|---|---|
| 发布 | `game_started` | GameRoot（装配完成时） |
| 发布 | `map_loaded` / `map_unloaded` / `travel_started` / `travel_completed` | SceneLoader 同名转发 |
| 发布 | `ui_notification` / `quest_advanced` | SaveHandler（读档失败）、DemoQuest |
| 订阅 | `travel_requested` | SceneLoader（战略图 → 场景图） |
| 订阅 | `game_saving` / `game_loaded` | SaveHandler |
| 订阅 | `interior_exited` | TravelHandler（室内退出检查；`mega_interior_entered/exited` 已无订户，信号定义保留待室内 v3 接回） |
| 订阅 | `strategic_map_closed` | SystemSetup（恢复场景图输入） |
| 订阅 | `squad_created` / `battle_started` / `battle_ended` / `territory_state_changed` | DemoQuest（目标链推进） |

---

## 依赖

组合根按依赖分层自上而下装配（`scripts/setup/system_setup.gd` 步骤表），全部经各模块 `api.gd` 或其自包含场景：

- 玩法/视图模块：`modules/units/`（实体场景经 UnitsAPI 常量）、`modules/player_control/`、`modules/combat/`、`modules/construction/`、`modules/organization/`、`modules/resources/`、`modules/inventory/`、`modules/expansion/`、`modules/town_life/`（TownLifeAPI 村民配比与职业外观）
- 基础设施模块：`modules/ui_global/`（UIRoot/UIKit/模态栈/HUD 部件）、`modules/debug_gui/`、`modules/fx/`、`modules/environment/`（EnvironmentSystem 挂在 game_root.tscn）、`modules/world_map/`（战略图 L1/L2/L3 场景）、`modules/hd2d/`（HD-2D 3D 街景世界场景）、`modules/texture_gen/`（城墙烘卡贴图生成）
- Autoload：EventBus / WorldState / SaveManager / TimeManager / AudioManager / BalanceConfig（装配首步 reload）/ DebugApi
- 依赖分层与边表以 `tools/audit_deps.py` 实测为准

---

## 开发注意事项

### 新增一张可旅行地图

1. 建场景 `scenes/maps/<map_id>.tscn`：HD-2D 图根节点挂 `scripts/map/hd2d_street_map.gd` 或其子类（变体先例：`hd2d_battlefield_map.gd`、`hd2d_resource_map.gd`；L1 聚落用薄实例场景，`layout_name`+`city_tier` 走 CityGen 确定性生成）。
2. 在 `scripts/game_root.gd` 头部 MAP_ID 常量区加常量，`_register_default_maps()` 中 `scene_loader.register_map(...)`（map_id + 场景 + `WorldAPI.MapType`）。
3. 连旅行链：同函数中 `register_map_exit(...)` 登记左右缘出口；或在场景内放 ChunkTrigger（`scripts/loading/chunk_trigger.gd`，`target_map_id` 留空走出口表、填值则硬目标）。HD-2D 街景类图覆写宿主 `_exit_specs()` 自动建边界触发器。
4. 地图显示名登记 `config/scene_map/map_titles.json`（城门选项框与舆图读取）。
5. L1 聚落类地图由 `tools/worldgen/l1/settlement_mapgen.py` 产出，map_id 与战略图数据的 settlement 一一对应。

### 新增地图宿主子组件

先例：ResourceGen（`scripts/map/resource_gen.gd`，由 HD-2D 宿主驱动）。在 `scripts/map/` 下新建 Node 脚本，由对应地图宿主挂载并 `setup(self)`；节点路径常量加在 `api.gd`。

### 新增常驻子系统 / 接入新玩法模块

1. 在 `scripts/setup/system_setup.gd` 的 `_step_table()` 追加 `[细分标签, Callable]` 步骤——顺序即依赖顺序；`setup()`（同步）与 `setup_steps()`（启动加载屏分帧）两条路共用同一张表。
2. 管理器实例挂 GameRoot 子节点；UI 面板走 `UIKit.full_rect()`/`widget()` + `ui_root.add_to_slot(...)` 槽位（禁止 `Control.new()` 当 UI 根）。
3. 需要被测试或 UI 消费的引用在 `game_root.gd` 补 getter。
4. 暂停语义：新系统默认随引擎总闸冻结（PAUSABLE）；需在暂停期存活的（快捷键/相机/UI）必须进 `game_root.gd` 头部 process_mode 分层表并注明理由。

### HD-2D 图上的 2D 画布元素

一切锚定实体位置的画布元素（悬浮框/飘字/粒子/提示面板）与屏幕点选判定，必须走 MapBase 视觉域协议（`remap_fx_pos` / `unmap_fx_pos` / `entity_hover_rect`）；数学核在 `scripts/map/hd2d_projection.gd`（正逆变换互为精确逆，有单测）。协议细则与推导见 [docs/技术/架构/建筑管线/HD-2D街景系统.md](docs/技术/架构/建筑管线/HD-2D街景系统.md)。

### 存档 SQL 纪律

`scripts/setup/save_handler.gd` 中表名/列名一律用固定常量，运行时值（slot_id/map_id）只经 `query_with_bindings` 绑定参数，禁止字符串拼接进 SQL。
