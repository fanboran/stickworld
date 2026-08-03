# modules — 功能模块总览

> **本目录是 Stick World 所有功能模块的容器**。每个子目录是一个自包含、对外只暴露 `api.gd` 的垂直切片。
> 本 README = 模块导览 + 核心架构摘要（从 `docs/` 解耦整合而来），开新模块或查模块边界时先看这里。

***

## 0. 目录约定

- **每个模块独立子目录**：`modules/<name>/`，根下必有 `api.gd`（公共契约）和（按需）`scenes/` `scripts/` `data/` `assets/` `ui/`
- **模块间通信两条路**：调 `api.gd`（同步、明确）；发 `EventBus` 信号（异步、解耦）
- **禁止**：`get_node("../OtherModule/...")` 跨模块引用、`extends` 另一个模块的内部类
- **命名**：文件/目录 `snake_case`，节点/类名 `PascalCase`
- **数据 vs 行为分离**：实体状态放 `RefCounted`/Resource 快照，行为放 `Node` 脚本

***

## 1. 模块速查表

| 模块                     | 职责                          | 状态          |
| ---------------------- | --------------------------- | ----------- |
| `world`                | 常驻主场景（GameRoot）+ 地图/相机/输入分发 | ✅ P0 完整     |
| `world/placement_grid` | 32px 竖向条带占地网格               | ✅ P0 完整     |
| `world_map`            | 战略图（鸟瞰多边形领土，玩家不在其中）         | 🟡 重构中      |
| `units`                | 火柴人角色（实体 + 骨骼 + AI）         | ✅ P0 完整     |
| `combat`               | 小队级战斗实例 + 编队/指令/掩体          | ✅ P0 完整     |
| `construction`         | 建造/升级/拆除/修理（运行时）            | ✅ P0 完整     |
| `building_gen`         | 程序化建筑生成（BuildingDef → 节点树）  | 🟡 B0-B2 阶段 |
| `texture_gen`          | CPU 贴图 + GPU Shader 材质库     | ✅ 完整        |
| `organization`         | 五层级通用组织管理（军/科/工/政/商）        | 🟡 部分       |
| `resources`            | 资源库存/价格/消耗/产出               | 🟡 待接入      |
| `technology`           | 科技解锁与研究（Demo 阶段以征服获得为主）     | 🟡 部分       |
| `environment`          | 跨场景天空/天气/光照/震动              | 🟡 仅光照      |
| `player_control`       | 输入分发 + 框选/编队 + 附身           | ✅ P0.7 完整   |
| `ui_global`           | 全局 UI 容器（UIRoot/HUD/弹窗层）+ 通用控件（小地图/缩放条/资源条） | ✅ P0 完整     |
| `debug_GUI`            | F3 调试覆盖层（占地/障碍/触发器可视化）      | ✅ P0 完整     |

> **已废弃**：`modules/world_map/scripts/world_map_controller.gd`（2026-07-16 重构为 `strategic_map_controller.gd`），待清理。

***

## 2. 模块依赖图

> **单向规则**：箭头方向 = "依赖"，高层依赖底层，低层不反向调用。`api.gd` 是允许的耦合点。

```
                            ┌──────────────┐
                            │  GameRoot    │  ← 常驻主场景（在 modules/world/scenes/）
                            │  (autoload 0)│
                            └──────┬───────┘
                                   │ 装配 + 注入
        ┌──────────────┬───────────┼──────────────┬──────────────┐
        ▼              ▼           ▼              ▼              ▼
   ┌─────────┐   ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌─────────┐
   │   ui    │   │  debug  │  │environ. │  │player_   │  │ world_  │
   │  (P0)   │   │  (P0)   │  │  ment   │  │ control  │  │   map   │  ← 战略图
   └────┬────┘   └────┬────┘  └─────────┘  └────┬─────┘  └────┬────┘
        │              │                          │            │
        │              │                          │            │
        ▼              ▼                          ▼            ▼
   ┌─────────────────────────────────────────────────────────────┐
   │              玩法系统层（核心循环）                          │
   │  organization  construction  combat  technology  resources  │
   │   (枢纽)         (建造)       (战斗)    (科技)     (经济)   │
   └────────┬─────────────────────────────────┬──────────────────┘
            │                                 │
            ▼                                 ▼
       ┌─────────┐                       ┌──────────┐
       │  units  │ ← 一切执行者           │  world   │ ← 场景图容器
       │  (AI)   │                       │ (maps)   │
       └────┬────┘                       └────┬─────┘
            │                                 │
            └────────────┬────────────────────┘
                         ▼
                  ┌────────────┐
                  │ building_gen│ ← 程序化建筑
                  │ texture_gen │ ← 纹理/材质（building_gen 单向依赖此）
                  └────────────┘
```

**关键路径**：

- `organization` 是枢纽：军事组织触发 `combat`、工程组织触发 `construction`、科研组织触发 `technology`、商业组织触发 `resources` 流动
- `units` 是被调用方：所有玩法系统通过 `units/api.gd` 拉取/驱动火柴人
- `world` 是场景图容器：所有运行实体（建筑、单位、组织实例）都挂在它的 `MapInstance` 下
- `world_map` 与 `world` 正交：前者是鸟瞰视图，玩家不在其中；后者是玩家实际所在

详见 [§6 模块间通信准则](#6-模块间通信准则) 与 [§9 EventBus 信号分类](#9-eventbus-信号分类)。

***

## 3. 模块详情

### 3.1 场景与地图

#### `modules/world/` — 场景图常驻容器

**职责**：常驻主场景（`GameRoot`）+ 地图实例（`MapInstance`）生命周期 + 相机/输入分发。

**关键节点结构**（`GameRoot.tscn`）：

```
GameRoot
├── EnvironmentSystem   # 跨场景光照/天气（P0 仅 CanvasModulate）
├── CameraRig            # 水平卷轴 + 1/4 区域跟随 + 缩放/震屏
├── SceneLoader          # 地图加载（地图间切换已实现，地图内 Chunk 流式为占位）
├── InputDispatcher      # 模式路由（EXPLORE/BUILD/BATTLE/POSSESS/INDOOR/UI）
├── WorldChunkHost       # 当前 MapInstance 挂载点
├── UIRoot               # 三层 UI 容器
└── BattleDirector       # 多战场调度
```

**地图类型**（见 `api.gd::MapType`）：

| 类型              | 用途        | 关键特性                                |
| --------------- | --------- | ----------------------------------- |
| `VILLAGE`       | 村落/定居点    | 水平卷轴 + PlacementGrid + BuildingHost |
| `BATTLEFIELD`   | 战场        | 同 VILLAGE，地形更空旷，BattleAnchor 挂战斗实例  |
| `ROAD`          | 村落间道路     | 双向 ChunkTrigger 出口                  |
| `INDOOR`        | 室内（铁匠铺等）  | 墙面透明化（INDOOR 模式）                    |
| `MEGA_INTERIOR` | 大建筑内部（宫殿） | 独立完整场景 + TELEPORT 旅行                |

**子模块**：[`placement_grid/`](file:///f:/VSCode/game-2/stick-world/modules/world/placement_grid/api.gd) — 32px 竖向条带占地网格（`occupy` / `release` / `is_occupied` / `is_blocked` / `can_place`）

**核心方法**：

- `WorldAPI.PATH_*` 常量：GameRoot 各子节点路径
- `MapType` / `TravelMode` / `EntrySide` 枚举

***

#### `modules/world_map/` — 战略图（鸟瞰多边形领土）

**职责**：玩家**不**在其中，是右上角小地图放大版。负责 L3/L2/L1 三级粒度缩放渲染、点击查询、模式切换、与场景图切换。

**关键设计**（区别于场景图）：

| 维度   | 战略图                 | 场景图        |
| ---- | ------------------- | ---------- |
| 玩家位置 | 不在其中                | 在其中        |
| 渲染内容 | 多边形 + 色块 + 图标       | 实际场景 + 火柴人 |
| 缩放语义 | 离散粒度切换              | 连续相机 zoom  |
| 触发   | Tab 打开 ModalOverlay | 默认         |

**三级粒度**（与 GDD §4.2 五层级对应）：

| 战略图粒度  | GDD 层级  | 数据模型            | 渲染策略               |
| ------ | ------- | --------------- | ------------------ |
| L3 大世界 | 第5层 帝国级 | `ContinentData` | 预渲染底图 + Shader 叠加  |
| L2 地区  | 第4层 行省级 | `RegionData`    | 预渲染底图 + 动态地标       |
| L1 地块  | 第3层 城市级 | `MapTileData`   | 地形底图 + **动态聚落建筑群** |

**ID 命名规范**（统一 String 类型）：

| 实体 | 格式                           | 示例                         |
| -- | ---------------------------- | -------------------------- |
| 大陆 | 固定                           | `"continent_main"`         |
| 地区 | `region_XXX`                 | `"region_001"`             |
| 地块 | `tile_XXX`                   | `"tile_042"`               |
| 聚落 | `settlement_<tile_id>_<idx>` | `"settlement_tile_042_03"` |
| 政权 | `state_XXX`                  | `"state_007"`              |
| 联盟 | `alliance_XXX`               | `"alliance_002"`           |

**核心信号**：`region_clicked` / `granularity_changed` / `map_mode_changed` / `region_owner_changed` / `settlement_updated` / `battlefront_updated` / `strategic_map_opened` / `strategic_map_closed`

**核心方法**：`set_granularity(level, parent_id)` / `query_at_screen(pos)` / `enter_settlement(settlement_id)` / `close_strategic_map()`

***

### 3.2 实体与角色

#### `modules/units/` — 火柴人角色系统

**职责**：游戏最小执行单位。包括渲染骨架、物理外壳、AI 决策、武器挂载、受伤判定。

**节点结构**：

```
StickmanEntity (CharacterBody2D)
├── StickmanRig (Skeleton2D)        # 渲染骨架（骨骼/纹理/动画/IK）
├── Hitbox (Area2D)                  # 受击判定
├── WeaponMount (Node2D)             # 武器挂载
├── HealthComponent (Node)           # HP/士气
├── AIController (Node)              # 🆕 AI 决策大脑
│   └── BehaviorStateMachine
│       ├── BehaviorIdle / Move / Wander / Work
│       ├── BehaviorAttack / SeekCover / Retreat / Flee
└── PossessionInterface (Node)       # 玩家附身接口
```

**行为状态机**（详见 §4.2 Stickman 状态机）。

**AI 三层命令系统**（决策来源优先级）：

```
┌──────────────────────────────────────┐
│ 1. 玩家/指挥链下达的指令（高）         │ ← tactical_orders → command_chain
├──────────────────────────────────────┤
│ 2. 编制默认战术（中）                 │ ← OrganizationState.autonomy_level
├──────────────────────────────────────┤
│ 3. 单位本能（低）                     │ ← behavior_xxx 内置触发
└──────────────────────────────────────┘
```

**公共 API**（节选）：

- `StickmanEntity.set_possessed(bool)` / `is_possessed()` / `get_facing()`
- `StickmanEntity.ai_move(dir, run)` / `ai_stop()` / `set_ground_constraints(...)`
- `StickmanRig.play(anim)` / `get_current_anim()` / `get_bone_by_id(id)`
- 常量：`ANIM_IDLE/WALK/ATTACK/DEAD`、`WeaponType`、`WALK_SPEED/RUN_SPEED`

***

### 3.3 玩法系统

#### `modules/combat/` — 战斗系统

**职责**：小队级战斗（10-30 人）。`BattleInstance` 是纯逻辑层，可挂到任何 `MapInstance.BattleAnchor`，不切场景。

**关键概念**：

- **战斗实例 vs 战场场景解耦**：`battle_instance.gd`（纯逻辑）拥有 `BattleAnchor` 节点（渲染战场），不依赖具体场景
- **三层命令系统**（详见 units）：玩家指令 → 编制默认 → 单位本能
- **指挥链延迟**：`base_delay × tier_diff × commander_efficiency_modifier`，玩家附身该层级时延迟为 0
- **战场导演**（`battle_ai_director.gd`）：每 2-5s 给单位打情绪标签（HESITANT/EXCITED/PANICKED/STEADY）→ 灵动性
- **队伍类型编制**（2026-08 新增）：编队由**编制预设**驱动（`config/formations/formation_presets.tres`），预设定义组织标签 + 职责范围（工作类型 WORK_COMBAT/BUILD/HAUL/FORAGE）+ 成员角色；职责范围可调整（`set_squad_work_types`）；AIController 决策按队伍职责过滤（建造队不参战/战斗班不接建造派工，未编队全能）；TacticalOrders 拒绝非战斗职责小队号令。UI 见 [`modules/combat/ui` 编制管理窗口（FormationPanel）](#modulescombat--战斗模块)

**预设号令**（P0 范围）：

| 号令                       | 效果        | 适用层级  |
| ------------------------ | --------- | ----- |
| `ORDER_ADVANCE_ALL`      | 全体向目标点前进  | L1-L2 |
| `ORDER_SPRINT`           | 加速冲刺（耗体力） | L1    |
| `ORDER_HOLD_POSITION`    | 原地坚守      | L1-L2 |
| `ORDER_RETREAT`          | 有序后撤      | L1-L2 |
| `ORDER_TAKE_COVER`       | 就近找掩体     | L1    |
| `ORDER_SUPPRESSING_FIRE` | 区域压制      | L1    |
| `ORDER_FLANK_LEFT/RIGHT` | 侧翼包抄      | L1-L2 |
| `ORDER_RALLY`            | 集结溃兵      | L2    |

**核心方法**：`start_battle(map, attacker_units, defender_units) -> BattleInstance` / `has_active_battle()` / `get_active_battles()`

***

#### `modules/construction/` — 建造系统

**职责**：建筑开工/升级/拆除/修理。由工程组织（tag=ENGINEERING）驱动。

**核心方法**：

- `start_construction(region_id, building_type, org_id)` → 创建 Project + 占 grid cell
- `get_buildings_in_region(region_id) -> Array[String]`
- `get_building_state(building_id)`
- `upgrade_building(building_id)` / `demolish_building(building_id)` / `repair_building(building_id, org_id)`

**信号**：`building_started` / `building_completed` / `building_removed` / `building_damaged` / `building_upgraded`

**工程量系统**（非固定建造时间）：

```
remaining_work = base_work                  # 例如铁匠铺 = 100 工时
每帧推进:
  work_done = worker_count × efficiency × delta
  remaining_work -= work_done
  if remaining_work <= 0: complete()
```

> **关联**：建筑程序化生成已迁出至 [`building_gen/`](#modulesbuilding_gen--程序化建筑生成)，本模块只管"何时建/拆"，不管"长得什么样"。

***

#### `modules/building_gen/` — 程序化建筑生成

**职责**：从 `BuildingDef` 配方（`.tres`）→ 节点树，运行时实例化。

**核心理念**（与"预制场景"对比）：

```
旧：bld_smithy_lv1.tscn (预制场景，复制粘贴改)
新：BuildingDef (数据配方) ──→ BuildingGen.generate() ──→ BuildingEntity (节点树)
```

**四类 Resource**（均在 `config/buildings/` 下）：

- `BuildingDef`：尺寸/材质/模块布局
- `ModuleDef`：单个功能模块（锻造/住所/仓库...）
- `MaterialDef`：材质属性（thatch/wood/stone/brick + 视觉参数）
- `RoofShape`：屋顶形状

**BuildingEntity 节点结构**：

```
BuildingEntity (Node2D)
├── Layers[0..N-1]
│   └── BuildingLayer
│       ├── BackLayer z=0    # 后景墙/柱
│       ├── Floor z=4         # 始终可见
│       ├── Modules_Slot z=5  # 本层模块
│       └── FrontLayer z=10   # 前景墙/柱（模块格处自动挖洞）
├── Roof z=11                 # 屋顶
├── InteractionZone (Area2D)
├── EnterTrigger (Area2D)     # 可选，传送触发
├── PassageBarrier (Area2D)
└── Footprint (CollisionShape2D)
```

**阶段**：B0 最小显示通 → B1 thatch+wood+挖洞 → B2 材质补齐 → B3 模块系统 → B4 多材质混合

> **依赖**：单向依赖 [`texture_gen/`](#modulestexture_gen--程序化纹理材质)；`texture_gen` 不依赖 `building_gen`。

***

#### `modules/texture_gen/` — 程序化纹理/材质

**职责**：所有程序化纹理和 Shader 材质。从 `building_gen` 解耦而来（2026-07）。

**两层实现**：

- **CPU 贴图**：`procedural_materials.gd` 用 `Image` 类合成（小尺寸/一次性）
- **GPU Shader**：`materials/<name>/shaders/<name>.gdshader`（大尺寸/参数化）

**已注册材质**：`thatch` / `stone_wall` / `stone_band` / `stone_window`

**API**：`make_wood_pillar/plank` / `make_straw_thatch` / `make_thatch_layered` / `make_stone_dark` / `make_metal_iron` / `load_shader_material(id)` / `apply_material(target, id)`

***

#### `modules/organization/` — 组织系统（核心枢纽）

**职责**：五层级通用管理单元。军队、科学院、工程队、行政、商队共享同一套底层。

**属性关键字段**：`tag`（MILITARY/RESEARCH/ENGINEERING/ADMINISTRATION/COMMERCE）、`tier`（1-5）、`parent_org` / `child_orgs`、`commander_id`、`personnel_template` / `equipment_template`、`autonomy_level`（HIGH/MEDIUM/LOW）、`default_behavior`、`current_project`

**状态机**：`FORMING → ACTIVE → EXECUTING → ACTIVE → DISBANDED`

**层级规则**：

- `tier` 相对上下级必须连续（不能 L5 直辖 L3）
- 可"跳过"某一层：创建空壳 Organization 或不创建
- L1 可额外展开 2 个子层（排→班→组）

**项目分解机制**（核心）：

```
L4 攻占北方行省
  └→ L3 第1团攻A城 / 第2团攻B城 / 第3团牵制C城
       └→ L2 第1连突破城墙 / 第2连清理街区 / 工兵连修桥
            └→ L1 火力组A压制塔楼 / 火力组B掩护街道
```

每层只知道自己要做什么，模拟真实指挥链的信息不对称。

**核心方法**：

- `create_organization(name, tag, tier, parent_id)`
- `set_personnel_template` / `set_equipment_template` / `set_autonomy` / `set_default_behavior`
- `assign_commander` / `assign_stickman` / `disband_organization`
- `insert_tier` / `remove_tier`（层级调整）
- `load_preset` / `export_as_preset`

***

#### `modules/resources/` — 资源/经济系统

**职责**：资源库存、价格、消耗、产出、转移（运输系统调用）。

**P0 范围（4 种基础资源）**：

| id                  | 名称   | initial\_price | 重量/单位 | 易腐 |
| ------------------- | ---- | -------------- | ----- | -- |
| `res_wood`          | 木材   | 3              | 2     | 否  |
| `res_stone`         | 石料   | 4              | 5     | 否  |
| `res_metal_ore`     | 金属矿  | 8              | 8     | 否  |
| `res_black_asphalt` | 黑色沥青 | 15             | 6     | 否  |

> P0 阶段资源列表以 GDD 为准，加工品/奢侈品（铁锭/丝绸）待 GDD §2.2 补充后激活。

**库存模型**：按 region\_id 分区 `{resource_id: {region_id: amount}}`

**核心方法**：

- `get_stock(resource_id, region_id)` / `get_all_stocks()` / `get_price(resource_id, region_id)`
- `consume(resource_id, amount, region_id, reason)` → 发射 `resource_changed` / `resource_not_enough`
- `produce(resource_id, amount, region_id, source)`
- `transfer(resource_id, amount, from_region, to_region)`（运输系统调用）
- `set_price_ceiling` / `set_price_floor` / `set_tax_rate`（L4+ 层级可用）

**信号**：`resource_changed` / `resource_not_enough` / `price_changed`

***

#### `modules/technology/` — 科技系统

**职责**：科技解锁与研究。

**获取机制**（Demo 阶段）：

| 方式       | 说明                                    |
| -------- | ------------------------------------- |
| **征服抢夺** | 打下敌国/占领特定地区 → 解锁对方科技（unlocked = true） |
| **事件获取** | 遗迹探索、特殊事件触发                           |
| **自主研究** | 后期帝国规模，组织科学院研究（Demo 阶段不启用）            |

> Demo 阶段科技主要通过**征服获得**，获得即拥有，无 AVAILABLE/RESEARCHING 状态机。

**核心方法**：

- `start_research(tech_id, org_id)` → 需 org 标签=RESEARCH
- `get_available_techs()` / `get_researching_techs()` / `get_unlocked_techs()` / `get_tech_state(tech_id)`
- `assign_researchers(org_id, researcher_ids)`
- `pause_research` / `resume_research`

**信号**：`tech_started` / `tech_paused` / `tech_resumed` / `tech_completed`

***

### 3.4 基础设施

#### `modules/player_control/` — 玩家输入与控制

**职责**：输入分发、框选/编队、战术指令、附身操控。

**输入模式枚举**：

| 模式        | 用途              | 切换触发                  |
| --------- | --------------- | --------------------- |
| `EXPLORE` | 探索（默认）          | 启动 / 离开交互区            |
| `BUILD`   | 建设（选址中）         | 按 B 或点建造菜单            |
| `BATTLE`  | 战斗（可框选/下令）      | 城镇被袭 / 进入战场           |
| `POSSESS` | 附身单兵            | BattlePanel "附身选中单位"  |
| `INDOOR`  | 室内（EXPLORE 子模式） | 进入/离开 InteractionZone |
| `UI`      | 模态弹窗            | 打开暂停菜单/战略图            |

**附身流程**：

1. BATTLE 模式框选单位
2. BattlePanel "附身选中单位" → `InputDispatcher.enter_possess_mode()`
3. `PossessionInterface._on_mode_activated` 从 SelectionSystem 取选中单位
4. `entity.set_possessed(true)` + CameraRig 居中跟随 + TimeManager 降速
5. WASD 移动 / 鼠标左键攻击 / ESC 退出
6. 退出时恢复之前模式和时间速度

***

#### `modules/ui_global/` — 全局 UI 层

**职责**：跨模块共享的 UI 容器与通用控件。**不放**深度耦合某业务模块的面板（那些放 `modules/<模块>/ui/`，见下方权责划分）。

```
UIRoot
├── GlobalHUD              # 顶层常驻：时间速度、资源数、通知、居中模式
├── ModePanel              # 模式容器：Village/Battle/Possess 槽位（内容由各模块装配）
├── ContextPanel           # 上下文容器：选中什么显示什么
├── Minimap                # 小地图（屏幕正上方中央，详见 §6.4）
├── ZoomBar / ResourceBar / ClockWidget  # 通用 HUD 控件
└── ModalOverlay           # 弹窗容器（暂停/设置/存档/编制/战略图）
```

**全局 UI 与模块专属 UI 的权责划分**：

| 归属 | 内容 |
|------|------|
| `modules/ui_global/` | 容器（UIRoot/HUD/ModePanel/ContextPanel/ModalOverlay）、通用 HUD 控件（小地图/缩放条/时钟/资源条）、游玩指示器、全局弹窗（设置/存档，不绑业务模块） |
| `modules/<模块>/ui/` | 深度耦合该模块 API 的业务面板（如 `combat/ui/` 战斗面板与编制窗口、`construction/ui/` 建造菜单、`player_control/ui/` 附身面板、`world_map/ui/` 战略图面板） |

**依赖注入约定**（2026-08 审计后统一）：

- UI 组件一律由 `SystemSetup` 装配时通过 `setup(...)` 注入依赖（CameraRig / GameRoot / 各系统引用），**禁止**自行向上遍历祖先或遍历 `get_tree().root` 查找（历史反模式已清除）
- 业务面板通过 `has_method` 防御式调用注入的引用；跨模块数据查询走模块 API（如小地图用 `VillageMap.get_minimap_buildings()`，不遍历地图节点树）
- 共享 HUD 布局常量（小地图/缩放条尺寸位置）定义在 `ui_global/api.gd` 的 `HUD_*`，禁止各文件硬编码

**小地图**（§10.4）：

- 缩略图（地图加载时生成） + 视野框（红色，来自 CameraRig）+ 角色点（绿色）+ 建筑图标
- 左键点击 → 相机 RTS 式跳转（暂停自动跟随）

***

#### `modules/environment/` — 环境系统

**职责**：跨场景保持的天空/天气/光照/震动。

**P0 阶段**：仅时间→光照映射（`CanvasModulate.color` 按 `LIGHT_KEYFRAMES` 插值）

**P1 阶段**：天空 Shader（极光/星星/太阳月亮）、GPU 粒子天气（雨/雪/沙尘暴）、地面震动、生物群落基调

**API 常量**：`HOURS_PER_DAY = 24` / `LIGHT_KEYFRAMES`（8 个关键时刻颜色）

***

#### `modules/debug_GUI/` — 调试覆盖层

**职责**：F3 切换的调试可视化（F3 默认开启）。

**显示内容**（颜色编码）：

| 元素                  | 颜色  | 来源                            |
| ------------------- | --- | ----------------------------- |
| PlacementGrid 占用格   | 绿   | `PlacementGrid._cells`        |
| BuildMask 不可放建筑格    | 红   | `PlacementGrid.blockage_mask` |
| WalkBarrier 地图障碍    | 蓝   | `MapInstance.WalkBarrier`     |
| PassageBarrier 建筑障碍 | 紫   | 各建筑 `PassageBarrier`          |
| ground\_y 地面线       | 黄   | `MapInstance.ground_y`        |
| ground\_bottom 地面底线 | 青   | `MapInstance.ground_bottom`   |
| 建筑边界框               | 白   | BuildingHost 子节点              |
| Chunk 触发器范围         | 紫矩形 | `MapInstance.ChunkTriggers`   |
| 火柴人状态文字             | 白   | EntityHost                    |

**API**（autoload 单例 `DebugApi`）：

- `register_drawer(name, callable)` / `unregister_drawer(name)`
- `toggle_visibility()` / `is_visible()` / `show_legend()` / `hide_legend()`
- 信号：`visibility_changed` / `legend_visibility_changed`

***

## 4. 核心架构概念

> 以下是从 `docs/技术/架构/` 解耦整合的核心约定。在 `modules/` 下开发时**优先遵守**本节，遇到模糊再回查 docs 详情。

### 4.1 战略图 vs 场景图（术语基线）

| 术语      | 英文            | 定义                            | 模块          | 玩家是否在其中 |
| ------- | ------------- | ----------------------------- | ----------- | ------- |
| **战略图** | Strategic Map | 鸟瞰多边形领土的"看地图"，用于指挥/缩放/外交/查看版图 | `world_map` | **否**   |
| **场景图** | Scene Map     | 玩家实际所在的卷轴/独立场景，火柴人在其中真实移动     | `world` 等   | **是**   |

**类比**：P 社游戏中"政治地图模式"（战略图）vs"打开一个省份看战斗"（场景图）。

**GDD §6.7 的六类地图全部是场景图**（村落/战场/道路/室内/大建筑/山坡）。战略图是正交的第七类。

**缩放语义不同**：

- 战略图缩放 = 离散粒度切换（L3→L2→L1→ 切场景图）
- 场景图缩放 = 连续相机 zoom

***

### 4.2 核心实体与状态机

> 游戏中一切"东西"的数据结构和生命周期。所有数值 `[PLACEHOLDER]`。

| 实体               | 简述       | 数量级                     |
| ---------------- | -------- | ----------------------- |
| **Stickman**     | 火柴人个体    | 初期 5-50，帝国级 1000-10000+ |
| **Building**     | 建筑       | 数十到数百                   |
| **Organization** | 五层级组织    | 数个到数十                   |
| **Project**      | 项目（执行单位） | 并行数十个                   |
| **Region**       | 地块       | 几十到上百                   |
| **Resource**     | 资源       | 库存追踪                    |
| **Technology**   | 科技       | 数十到上百项                  |
| **Battle**       | 战斗实例     | 并行 0-10+                |
| **SupplyChain**  | 物流链路     | 数十条                     |

#### Stickman（火柴人）状态机

```
                    ┌─────────────────────┐
                    │       DEAD          │  终态，不可逆
                    └─────────────────────┘
                              ▲
                              │ hp <= 0
                              │
    ┌─────────┐       ┌───────┴───────┐       ┌──────────┐
    │  IDLE   │ ────→ │    MOVING     │ ────→ │ WORKING  │
    └─────────┘       └───────────────┘       └──────────┘
         ▲                 │    ▲                    │
         │                 │    │                    │
         │  任务完成       │    │  路径被阻            │  任务完成
         │                 ▼    │                    ▼
         │           ┌──────────┴──┐           ┌──────────┐
         └───────────│  FIGHTING   │←──────────│ FLEEING  │
                     └─────────────┘  士气崩溃  └──────────┘
```

**转换条件**：

| 从        | 到        | 条件             |
| -------- | -------- | -------------- |
| IDLE     | MOVING   | 收到移动指令 / 自主决定  |
| MOVING   | IDLE     | 到达目标 / 指令取消    |
| MOVING   | WORKING  | 到达工作地点         |
| WORKING  | IDLE     | 任务完成 / 体力耗尽    |
| IDLE     | FIGHTING | 检测到敌人 / 收到攻击指令 |
| FIGHTING | FLEEING  | 士气 < 崩溃阈值      |
| FLEEING  | IDLE     | 脱离战斗 + 到达安全位置  |
| 任意       | DEAD     | hp <= 0        |

**特殊规则**：

- 战时召唤：消耗 `res_black_asphalt` + 召唤师施法时间 → 立即生成
- 装备自动匹配：根据 `assigned_org` 的编制配置
- 帝国级 LOD：不在活跃视口内的火柴人用简化模拟（近/中/远/极远 四级 LOD）

#### Building 状态机

```
PLANNED ──→ CONSTRUCTING ──→ OPERATIONAL ──→ UPGRADING ──→ OPERATIONAL
                │                  │
                │ 建设中断          │ 被攻击
                ▼                  ▼
           PLANNED             DAMAGED ──→ OPERATIONAL (修复)
                                   │
                                   ▼
                              DESTROYED (终态)
```

**模块化扩展后**（B0+ 阶段）：`type` / `tier` 由更丰富数据组合取代：

| 新字段                              | 说明               |
| -------------------------------- | ---------------- |
| `def: BuildingDef`               | 定义尺寸/材质/模块/开口的配方 |
| `shell_dirty: bool`              | 材质或尺寸变更后需重建节点树   |
| `modules: Array[ModuleInstance]` | 各层已加载的模块实例       |
| `layers_material: Array[String]` | 每层材质 ID          |

**派生属性**：

- `max_hp` = `def.size` × 各层 `MaterialDef.stats.hp_per_cell` 求和
- `work_required` = `def` + `MaterialDef.stats.work_per_cell` 求和
- `worker_capacity` = 所有 `ModuleDef.work_slots_local` 数量求和

#### Organization 状态机

```
FORMING ──→ ACTIVE ──→ EXECUTING ──→ ACTIVE
  │            │            │
  │ 组建完成   │ 项目分配   │ 项目完成
  │            │            │
  └────────────┴────────────┘
               │
               ▼
          DISBANDED (解散，人员回归待分配池)
```

**关键**：Organization 本身不"做"事 — 它通过创建并委派 Project 来驱动实际行为。

#### Project 状态机

```
PLANNING ──→ EXECUTING ──→ COMPLETED
                │
                ├──→ PAUSED ──→ EXECUTING
                │
                └──→ FAILED
```

#### Battle 状态机

```
PREPARING ──→ ENGAGED ──→ ATTACKER_WIN / DEFENDER_WIN
                  │
                  ├──→ STALEMATE ──→ ENGAGED (突破僵局)
                  │
                  └──→ ROUT (一方士气崩溃)
```

#### SupplyChain 状态

`ACTIVE / BLOCKED / DEPLETED / CANCELLED`

#### 实体关系速查

```
Organization (1) ──owns──→ (N) Project
Organization (1) ──has───→ (N) Stickman
Organization (1) ──has───→ (0..N) Organization (child)
Organization (1) ──owns──→ (0..N) Building
Project     (1) ──decomposes──→ (0..N) Project (sub)
Project     (1) ──triggers───→ (0..1) Battle
Project     (1) ──creates────→ (0..N) SupplyChain
Region      (1) ──contains──→ (N) Building
Region      (1) ──contains──→ (N) Stickman
Region      (1) ──hosts─────→ (0..N) Battle
Technology  (1) ──unlocks───→ (N) Building/Equipment/Ability
```

***

### 4.3 核心玩法循环（五层级管理深度）

> Stick World 的核心 = **设计层级架构 → 观察自动化运转 → 发现问题 → 优化架构 → 帝国扩大**。

#### 时刻级循环（0-30 秒）

30 秒内必有可感知的反馈。

| 层级    | 典型动作        | 即时反馈        |
| ----- | ----------- | ----------- |
| L1 个体 | 移动/攻击/采集    | 打击感、粒子、音效   |
| L2 小队 | 下达移动/攻击指令   | 小队阵型变化、火力输出 |
| L3 编制 | 布置战术/调度     | 战线推进/建筑进度条  |
| L4 区域 | 签署法令/调整税率   | 报表数值变化      |
| L5 帝国 | 观察报表/调整制度参数 | 帝国效率指数变化    |

#### 会话级循环（1-3 小时）

```
审视帝国现状 → 发现问题/机会 →
    ├─ 调整军事编制/战术
    ├─ 调整科研架构/方向
    ├─ 调整经济参数
    └─ 颁布新法律 →
观察自动化运转（5-15 分钟）→
    ├─ 放大看某个战场/工地/城市
    ├─ 看报表
    └─ 发现新问题/瓶颈 →
干预/优化 → 回到循环起点
```

| 规模         | 干预频率       | 观察 vs 干预  |
| ---------- | ---------- | --------- |
| L1-L2（小规模） | 几乎持续       | 10% / 90% |
| L3（中等）     | 每 5-10 分钟  | 50% / 50% |
| L4-L5（帝国）  | 每 15-30 分钟 | 80% / 20% |

**后期更多是在"看海"** — 后期满足感来自**看自己设计的机器在跑**，而非操作。

#### 长期循环（整局：12-20h）

```
流浪 (L1个体) → 部落 (L1-L2) → 城市 (L2-L3) → 王国 (L3-L4) → 帝国 (L4-L5)
```

不是五个独立"阶段" — 是你的管理范围自然扩大，能使用的层级逐步解锁。

#### 工厂自动化类比

| 《戴森球计划》      | 本游戏            |
| ------------ | -------------- |
| 手搓采矿机 → 自动采矿 | 手操小队 → 指挥官自动指挥 |
| 设计产线 → 自动化生产 | 设计指挥链 → 自动作战   |
| 星际物流         | 全国物流网络         |
| 戴森球          | 统合世界           |
| 每个齿轮是你亲手放的   | 每个组织是你亲手搭建的    |

#### 防滚雪球

1. **管理复杂度超线性增长**：领土翻倍 ≠ 管理难度翻倍
2. **多线冲突**：长国境 → 多条战线 → 考验指挥链设计
3. **内部矛盾**：不同民族/文化的火柴人
4. **科技扩散**：敌人也会学你

***

### 4.4 五层级管理深度（战略图 → 场景图映射）

| GDD §4.2 层级 | 战略图覆盖？   | 视角                              | 数据/场景            |
| ----------- | -------- | ------------------------------- | ---------------- |
| 第5层 帝国级     | ✅ L3 大世界 | 看全大陆，地区色块 + 政权边界                | `ContinentData`  |
| 第4层 行省级     | ✅ L2 地区  | 看一个地区，地块多边形 + Q版图标              | `RegionData`     |
| 第3层 城市/郡县级  | ✅ L1 地块  | 看一个地块，聚落点位 + 道路 + 资源            | `MapTileData`    |
| 第2层 镇/村级    | ❌ 切到场景图  | 进入聚落 = `SceneLoader.load_map()` | `VillageMap` 等六类 |
| 第1层 个体/班组   | ❌ 场景图内附身 | `PossessionInterface`           | `StickmanEntity` |

> **关键设计原则**：战略图的"缩放"不是连续的相机 zoom，而是**离散的粒度切换**。从 L1 地块再往下缩放，就跳出战略图，进入场景图。

***

### 4.5 建筑三层架构（地形 / 初始 / 玩家）

| 层         | 存储格式                                     | 可破坏 | 加载时机      | 示例        |
| --------- | ---------------------------------------- | --- | --------- | --------- |
| **地形建筑层** | 地图场景 `.tscn` 中 `TerrainBuildings` 节点     | 否   | 随场景实例化    | 矿山、遗迹、大石头 |
| **初始建筑层** | 地图场景 `.tscn` 中 `InitialBuildingsList` 列表 | 是   | 地图加载后写入存档 | 关卡设计放的民居  |
| **玩家建筑层** | 存档 `.json`                               | 是   | 存档加载时实例化  | 玩家新建的农场   |

三者使用**同一套**建筑场景文件（`modules/building_gen/buildings/<id>.tscn`），只是加载时机不同。`PlacementGrid` 是统一占位登记表。

**拆除规则**：

- 地形建筑：玩家不能拆除（PlacementGrid 标记 `is_terrain=true`）
- 初始 + 玩家建筑：可拆除，释放格子，退还部分资源

***

## 5. 建筑系统约束（跨模块）

### 5.1 占地网格（32px 竖向条带）

- 横向卷轴游戏中，世界按 32px 宽切分为**竖向条带**，每个条带无限向上下延伸
- 建筑只占宽度（N 个条带），不关心垂直方向占地
- **一块地只能建一个建筑** = cell 占用检查
- 选址预览 = ghost 建筑半透明 + 网格高亮（绿=可建/红=冲突）

### 5.2 BuildMask 不可放建筑区域

`PlacementGrid.blockage_mask` 标记"地形上不可放建筑"的格子（大石头/山坡阶梯处/装饰物占地）。设计时在 `BuildMaskLayer` 节点下加 `ColorRect`（红色半透明，仅设计时可见），运行时注册到 `blockage_mask`。

### 5.3 通行障碍系统（WalkBarrier + PassageBarrier）

火柴人移动除了受 `ground_y`/`ground_bottom`/`map_left`/`map_right` 矩形约束外，还受两级透明障碍约束：

| 类型                   | 位置                        | 用途       | 调试色 |
| -------------------- | ------------------------- | -------- | --- |
| 地图级 `WalkBarrier`    | `MapInstance.WalkBarrier` | 悬崖/高楼边缘  | 蓝   |
| 建筑级 `PassageBarrier` | 各建筑 `PassageBarrier`      | 建筑本体不可通行 | 紫   |

### 5.4 室内与大建筑（INDOOR 模式）

**两种进入方式**：

| 方式       | 适用            | 触发                   | 场景变化                            | 模式切换                   |
| -------- | ------------- | -------------------- | ------------------------------- | ---------------------- |
| **透明化**  | 小型（铁匠铺/住宅/仓库） | 进入 `InteractionZone` | 前墙 alpha→0.3 + Interior 显示，不切场景 | EXPLORE → INDOOR       |
| **传送切换** | 大型（宫殿/地下城/堡垒） | 进入 `EnterTrigger`    | 加载 `MegaInteriorMap`            | EXPLORE → INDOOR (新地图) |

**INDOOR 是 EXPLORE 的子模式**（共用 ExploreHandler），仅作"当前在室内"标记供 UI/音效查询。

**多建筑透明化**：每建筑独立维护 `_interior_is_transparent`；离开某交互区时遍历全部建筑检查，全离开才 `exit_to_explore()`。

***

## 6. 模块间通信准则

> **两条路**：同步 `api.gd` 调用 + 异步 `EventBus` 信号。跨模块禁止直接 `get_node` 或引用非 API 内部方法。

### 6.1 同步 vs 异步选择

| 场景      | 方式           | 原因         |
| ------- | ------------ | ---------- |
| 查询地块资源  | 同步（api.gd）   | 即时查询，不需要异步 |
| 战斗消耗资源  | 异步（EventBus） | 多接收方，解耦    |
| 科技解锁新单位 | 异步（EventBus） | 多系统需要响应    |
| 组织解散    | 异步（EventBus） | 级联影响多个系统   |

### 6.2 通信规则

```
✅ 允许：模块 A → EventBus 信号 → 模块 B
✅ 允许：模块 A → api.gd → 模块 B（同步调用）
❌ 禁止：模块 A 直接访问模块 B 的内部脚本
❌ 禁止：跨模块信号形成循环
```

### 6.3 同步 vs 异步原则

- 同步（api）：调用方**需要返回值** / **必须等结果**才能继续
- 异步（EventBus）：调用方**只通知**事件，**不关心**谁接收

***

## 7. 数据流全景

```
玩家输入
  ↓
组织系统（核心枢纽）
  ├─→ 战斗系统（MilitaryCampaign Project → Battle）
  ├─→ 科技系统（Research Project）
  └─→ 建设系统（Construction Project）
       ↓
    资源系统（接收所有消耗请求，价格信号调节生产）
       ↓
    运输系统（资源不瞬移，从产地流向消费地）
       ↓
    扩张系统（战斗结果 → 地块控制度变化）
```

**命令下发流**：

```
玩家选择"虎贲师" → 点击"进攻北方行省"
  → 组织系统创建 MilitaryCampaign Project
  → Project 分解为子 Project（师→团→营→连→排）
  → 每层 Project 分配给对应层级的 Organization
  → Organization 通过所属 Stickman 执行
  → 战斗系统检测敌对单位 → 创建 Battle 实例
```

**经济自动调节流**：

```
战争导致铁矿石需求↑
  → 资源系统检测需求-供给曲线变化
  → price_changed 信号（铁价上涨）
  → 商业组织自动调整商队路线
  → 民间采矿组织增加开采
  → 供给↑ → 价格回落 → 循环自稳定
```

**信息上报流**：

```
L1 排长 AI 检测到前方有大量敌军
  → 根据 autonomy_level 决定：
    - HIGH: 自主决定撤退/求援
    - LOW: 上报 L2 连长等待指令
  → org_efficiency_changed 反映在组织效率指标
  → 玩家在帝国概览看到"虎贲师·第三团·第二连·士气下降"
  → 缩放查看 → 发现问题 → 调整策略
```

***

## 8. 存储分层

| 层         | 内容                                | 格式                  | 持久化             |
| --------- | --------------------------------- | ------------------- | --------------- |
| **静态配置**  | 实体定义（建筑/单位/科技/资源/组织预设）            | `.tres` Resource    | 随包发布            |
| **关卡数据**  | 地图定义（VillageMap / BattlefieldMap） | `.tres`             | 随包发布            |
| **程序化产物** | L3 大陆/地区/地块 JSON + 风格化底图 PNG      | JSON + PNG          | 开发期 Python 生成   |
| **运行时状态** | WorldState（所有实体快照）                | RefCounted/Resource | 内存              |
| **存档**    | 游戏进度（建筑实例/组织/单位/资源）               | `.json`             | SaveManager 持久化 |

**配置目录**：

```
config/
├── units/                  # 火柴人基础属性
├── buildings/              # 建筑配方（BuildingDef / ModuleDef / MaterialDef）
├── tech_tree/              # 科技树
├── resources/              # 资源定义
├── organizations/          # 组织预设模板
├── strategic_map/          # 战略图数据（manifest.tres + regions/ + tiles/）
├── balance/                # 全局平衡变量（可热加载）
├── maps/                   # 地图定义
└── excel/                  # Excel 数据源（导入 → .tres）
```

***

## 9. EventBus 信号分类

> 完整信号清单见 `core/autoload/event_bus.gd`。本节只列主要分类（按发射方-接收方）。

### 9.1 资源/经济事件

| 信号                    | 参数                                               | 触发   |
| --------------------- | ------------------------------------------------ | ---- |
| `resource_changed`    | resource\_id, amount, delta, region\_id          | 库存变化 |
| `resource_not_enough` | resource\_id, required, available, region\_id    | 不足   |
| `price_changed`       | resource\_id, old\_price, new\_price, region\_id | 价格波动 |
| `trade_completed`     | from\_region, to\_region, resource\_id, quantity | 商队到货 |

### 9.2 人口/单位事件

| 信号               | 参数                      | 触发     |
| ---------------- | ----------------------- | ------ |
| `unit_recruited` | unit\_id, org\_id       | 新火柴人加入 |
| `unit_lost`      | unit\_id, cause         | 阵亡     |
| `unit_summoned`  | unit\_id, asphalt\_cost | 沥青召唤   |
| `commander_died` | org\_id, commander\_id  | 指挥官阵亡  |

### 9.3 建筑事件

| 信号                                     | 参数                                 | 触发      |
| -------------------------------------- | ---------------------------------- | ------- |
| `building_started`                     | project\_id, region\_id            | 开工      |
| `building_completed`                   | building\_id, region\_id           | 完工      |
| `building_removed`                     | building\_id, region\_id           | 拆除/摧毁   |
| `building_damaged`                     | building\_id, damage\_amount       | 被攻击     |
| `building_upgraded`                    | building\_id, old\_tier, new\_tier | 升级      |
| `interior_entered` / `interior_exited` | building\_id                       | 进出室内交互区 |

### 9.4 战斗事件

| 信号                 | 参数                                         | 触发     |
| ------------------ | ------------------------------------------ | ------ |
| `battle_started`   | battle\_id, region\_id, attacker, defender | 战斗开始   |
| `battle_ended`     | battle\_id, result, casualties             | 战斗结束   |
| `battle_stalemate` | battle\_id, duration                       | 进入僵持   |
| `supply_line_cut`  | org\_id, supply\_id                        | 补给被切断  |
| `tactical_event`   | battle\_id, event\_type, data              | 关键战术事件 |

### 9.5 科技/扩张/组织/项目/UI 事件

| 类别 | 主要信号                                                                               |
| -- | ---------------------------------------------------------------------------------- |
| 科技 | `tech_researched` / `tech_started` / `tech_stalled`                                |
| 扩张 | `territory_gained` / `territory_lost` / `coalition_formed` / `treaty_signed`       |
| 组织 | `org_created` / `org_disbanded` / `org_restructured` / `org_efficiency_changed`    |
| 项目 | `project_created` / `project_completed` / `project_failed` / `project_decomposed`  |
| UI | `ui_notification` / `ui_switch_view` / `ui_zoom_level_changed` / `ui_possess_unit` |

**信号准则**：

1. **不循环发射**：A 发射信号触发 B，B 不能在做完后发射原信号回去
2. **参数不可变**：信号参数是快照副本
3. **单向事件流**：信号从数据层 → UI 层
4. **safe\_emit**：发射前检查信号是否存在

***

## 10. Autoload 依赖

> 全局单例清单（来自 `project.godot`）。**严禁修改** **`core/`**，新增 autoload 需经批准。

| 名称                 | 脚本                                       | 职责          |
| ------------------ | ---------------------------------------- | ----------- |
| `EventBus`         | `core/autoload/event_bus.gd`             | 全局事件总线（零依赖） |
| `ConfigManager`    | `core/autoload/config_manager.gd`        | 用户设置读写      |
| `SaveManager`      | `core/autoload/save_manager.gd`          | 存档/读档       |
| `SceneManager`     | `core/autoload/scene_manager.gd`         | 场景/视图切换     |
| `AudioManager`     | `core/services/audio_manager.gd`         | 音频播放        |
| `_mcp_game_helper` | `addons/godot_ai/runtime/game_helper.gd` | 第三方 AI 工具   |
| `DebugApi`         | `modules/debug_GUI/api.gd`               | 调试覆盖层管理     |

**初始化顺序**（自上而下）：

```
EventBus（零依赖，最先）
  → ConfigManager / TimeManager
    → AudioManager（依赖 ConfigManager）
      → SaveManager（依赖 WorldState + EventBus）
        → SceneManager（依赖 SaveManager + EventBus）
```

**职责边界**：

| Autoload      | 负责              | 不负责                     |
| ------------- | --------------- | ----------------------- |
| EventBus      | 信号注册、safe\_emit | 不存任何游戏状态                |
| ConfigManager | 用户设置读写          | 不存游戏配置（→ BalanceConfig） |
| SaveManager   | 存档读写、模块注册       | 不定义存档内容格式               |
| SceneManager  | 场景/视图切换         | 不定义场景内容                 |
| AudioManager  | 音频播放            | 不定义何时播放                 |

***

## 11. 新增模块 checklist

1. ☐ 在 `modules/<name>/` 下建目录，根放 `api.gd`（公共契约，extends Node 或 RefCounted）
2. ☐ 确定模块类型（Node vs RefCounted）：
   - **Node**：需要信号、节点生命周期、挂在场景树（如 combat / construction / organization）
   - **RefCounted**：纯数据/工具（api.gd 是常量/枚举的集合，如 units / world / environment / ui）
3. ☐ 在 `api.gd` 定义 `setup(...)` 注入内部管理器引用
4. ☐ 关键事件通过 `EventBus` 发射（数据层 → UI），不直接调其他模块
5. ☐ 跨模块依赖走 `api.gd`，**禁止**直接 `extends` 其他模块内部类
6. ☐ 实体状态用 `RefCounted`/Resource 快照；行为用 `Node` 脚本
7. ☐ 文件命名：`snake_case`；节点/类名 `PascalCase`
8. ☐ 子目录按需：`scenes/` `scripts/` `data/` `assets/` `ui/`
9. ☐ 同步本 README §1 模块速查表
10. ☐ 在 `docs/技术/架构/模块API契约.md` 添加公共方法签名

***

## 12. 相关文档（按需查阅）

> 本 README 是模块视角的导览 + 架构摘要。深入细节时回到 `docs/`：

| 主题                 | 文档                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------- |
| 整体设计（GDD，唯一真相源）    | [`docs/设计/游戏设计文档.md`](file:///f:/VSCode/game-2/docs/设计/游戏设计文档.md)                     |
| 核心循环               | [`docs/设计/核心循环.md`](file:///f:/VSCode/game-2/docs/设计/核心循环.md)                         |
| 场景与战斗架构（P0 工程基线）   | [`docs/技术/架构/场景与战斗架构.md`](file:///f:/VSCode/game-2/docs/技术/架构/场景与战斗架构.md)             |
| 战略图架构              | [`docs/技术/架构/战略图架构.md`](file:///f:/VSCode/game-2/docs/技术/架构/战略图架构.md)                 |
| 战略图数据流             | [`docs/技术/架构/世界地图数据流.md`](file:///f:/VSCode/game-2/docs/技术/架构/世界地图数据流.md)             |
| 模块 API 契约（签名+前置后置） | [`docs/技术/架构/模块API契约.md`](file:///f:/VSCode/game-2/docs/技术/架构/模块API契约.md)             |
| EventBus 信号完整清单    | [`docs/技术/架构/系统交互与EventBus.md`](file:///f:/VSCode/game-2/docs/技术/架构/系统交互与EventBus.md) |
| Autoload 依赖图       | [`docs/技术/架构/自动加载依赖.md`](file:///f:/VSCode/game-2/docs/技术/架构/自动加载依赖.md)               |
| 核心实体/状态机（完整版）      | [`docs/技术/架构/核心实体与状态机.md`](file:///f:/VSCode/game-2/docs/技术/架构/核心实体与状态机.md)           |
| 建筑模块化设计            | [`docs/技术/架构/建筑模块化设计.md`](file:///f:/VSCode/game-2/docs/技术/架构/建筑模块化设计.md)             |
| 数据流与存储             | [`docs/技术/架构/数据流全景.md`](file:///f:/VSCode/game-2/docs/技术/架构/数据流全景.md)                 |
| 存储架构               | [`docs/技术/架构/存储架构设计.md`](file:///f:/VSCode/game-2/docs/技术/架构/存储架构设计.md)               |
| 开发规范               | [`docs/技术/规范/开发指南.md`](file:///f:/VSCode/game-2/docs/技术/规范/开发指南.md)                   |
| 建筑系统教程             | [`docs/技术/教程/建筑系统教程.md`](file:///f:/VSCode/game-2/docs/技术/教程/建筑系统教程.md)               |
| 项目进度               | [`docs/项目/项目进度.md`](file:///f:/VSCode/game-2/docs/项目/项目进度.md)                         |
| GDD vs 实现差异        | [`docs/项目/GDD与实现差异分析.md`](file:///f:/VSCode/game-2/docs/项目/GDD与实现差异分析.md)             |
| 贡献指南               | [`docs/CONTRIBUTING.md`](file:///f:/VSCode/game-2/docs/CONTRIBUTING.md)               |
| 文档总索引              | [`docs/README.md`](file:///f:/VSCode/game-2/docs/README.md)                           |

***

*本 README = 模块视角的导览 + 架构摘要（从 docs/ 解耦整合）。设计变更先改 docs 对应章节，再同步本 README。*
