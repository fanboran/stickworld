# 系统交互矩阵与事件目录

> 底层架构第二阶段：定义各系统之间的交互关系，以及 EventBus 信号的完整目录。

> **信号唯一真相源是 `core/autoload/event_bus.gd`**。本文件是设计视图的交互矩阵与目录索引；
> 状态变更类信号（资源/建筑/组织等）由对应模块 `api.gd` 自建，EventBus 不重复声明。
> 未实现系统（扩张/物流/科技/项目等）不预先占位信号，实现时按当时契约在 EventBus 或模块 api 中声明。

---

## 一、系统交互矩阵

**图例**：
- ✅ = 意图交互（设计意图就是这两个系统要通信）
- ⚠️ = 可接受交互（不是设计意图，但不认为是 Bug）
- ❌ = Bug（这两个系统不应直接通信）
- - = 无交互

| ↓ 发射 \ 接收 -> | 经营建设 | 科技 | 资源 | 扩张 | 建设 | 组织 | 战斗 | 运输 |
|:----------------|:--------:|:----:|:----:|:----:|:----:|:----:|:----:|:----:|
| **经营建设** | - | ✅ | ✅ | ✅ | ✅ | ✅ | - | - |
| **科技** | ✅ | - | ✅ | - | ✅ | ✅ | ✅ | - |
| **资源** | ✅ | ✅ | - | - | ✅ | ✅ | ✅ | ✅ |
| **扩张** | ✅ | - | ✅ | - | - | ✅ | ✅ | - |
| **建设** | ✅ | - | ✅ | - | - | ✅ | - | ✅ |
| **组织** | ✅ | ✅ | ✅ | ✅ | ✅ | - | ✅ | ✅ |
| **战斗** | ✅ | - | ✅ | ✅ | - | ✅ | - | ✅ |
| **运输** | ✅ | - | ✅ | - | ✅ | ✅ | ✅ | - |

### 关键交互说明

| 交互对 | 类型 | 说明 |
|--------|------|------|
| 组织->一切 | ✅ | 组织是核心枢纽。军事组织触发战斗，工程组织触发建设，科研组织触发科技，商业组织触发资源流动 |
| 战斗->资源 | ✅ | 战斗消耗资源（弹药/食物/沥青），战胜获得资源（缴获） |
| 战斗->扩张 | ✅ | 战胜->获得地块控制度 |
| 运输->战斗 | ✅ | 运输断供->前线战斗力下降 |
| 科技->组织 | ✅ | 科技解锁新的编制类型/组织能力 |
| 资源->科技 | ✅ | 科研消耗资源（纸/墨/实验材料/沥青） |
| 建设->运输 | ✅ | 修路->运输效率提升 |
| 经营建设->一切 | ✅ | 经营建设是所有循环的起点和终点 |

---

## 二、EventBus 事件目录（现行）

> 与 `core/autoload/event_bus.gd` 逐条对齐。共 32 个信号。

### 2.1 生命周期事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `game_started` | - | GameRoot | 所有系统 | 新游戏开始 |
| `game_loaded` | slot_index: int | SaveManager | 所有系统 | 存档加载完成 |
| `game_saving` | slot_index: int | SaveManager | 所有系统 | 开始存档 |
| `game_saved` | slot_index: int | SaveManager | UI | 存档完成 |
| `game_paused` | - | 玩家/系统 | 所有系统 | 暂停 |
| `game_resumed` | - | 玩家/系统 | 所有系统 | 恢复 |

### 2.2 资源/经济/建筑/组织事件（模块 api.gd 自建，不经 EventBus）

| 类别 | 信号 | 参数 |
|------|------|------|
| 资源 | `resource_changed` / `resource_not_enough` / `price_changed`（resources/api.gd） | resource_id, ... |
| 建筑 | `building_started` / `building_completed` / `building_removed`（construction/api.gd） | building_id: String, region_id: String |
| 建筑 | `building_damaged`（construction/api.gd） | building_id: String, damage_amount: float |
| 建筑 | `building_upgraded`（construction/api.gd） | building_id: String, old_tier: int, new_tier: int |
| 建筑 | `building_repaired`（construction/api.gd） | building_id: String, repair_amount: float |
| 组织 | `org_created` / `org_restructured` / `org_disbanded`（organization/api.gd） | org_id: String |

### 2.3 战斗事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `battle_started` | battle_id: String | 战斗系统 | UI、扩张系统 | 战斗开始 |
| `battle_ended` | battle_id: String, victory: bool | 战斗系统 | UI、扩张系统 | 战斗结束 |
| `team_ai_stance_changed` | battle_id: String, faction: int, from_stance: int, to_stance: int, reason: String | TeamAi | 调试 HUD、测试断言 | 阵营 AI 姿态切换（单向广播，暂无生产订户；0=GARRISON/1=DEFEND/2=ATTACK） |
| `heal_cast` | battle_id: String, caster_id: int, target_id: int, anim_name: String | WeaponMount | battle_sim 采样 | 治疗施放（单向广播，可观测性通道；anim_name ∈ {heal_meric_1, heal_meric_2}） |

### 2.4 编队事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `selection_changed` | unit_ids: Array | SelectionSystem | UI | 框选变化 |
| `squad_created` | squad_id: String, unit_ids: Array | FormationSystem | UI、Organization | 编队创建 |
| `quest_advanced` | quest_id: String | DemoQuest（world） | Construction UI | Demo 阶段目标推进（建造目标激活时按钮呼吸强调） |
| `order_issued` | order_type: int, target_squad_id: String, source_tier: int | TacticalOrders | UI、Units | 号令下达（source_tier=发令层级，0=玩家直接指挥） |
| `commander_assigned` | squad_id: String, unit_id: int | FormationSystem | UI | 任命指挥官 |

### 2.5 场景/地图/旅行/战略图事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `travel_requested` | map_id: String | world_map | SceneLoader | 玩家点击聚落进入场景图 |
| `map_loaded` | map_id: String, map_type: int | SceneLoader | UI / Environment | 地图加载完成 |
| `map_unloaded` | map_id: String | SceneLoader | UI | 地图卸载完成 |
| `chunk_loaded` | chunk_idx: int | SceneLoader | MapInstance | Chunk 加载完成 |
| `chunk_unloaded` | chunk_idx: int | SceneLoader | MapInstance | Chunk 卸载完成 |
| `travel_started` | from_id, to_id, mode: int | SceneLoader | UI / WorldClock | 旅行开始 |
| `travel_completed` | to_id: String | SceneLoader | UI | 旅行完成 |
| `strategic_map_opened` | - | world_map | UI / InputDispatcher | 战略图打开 |
| `strategic_map_closed` | - | world_map | UI / InputDispatcher | 战略图关闭 |

### 2.6 UI / 附身 / 室内事件

| 信号 | 参数 | 发射方 | 接收方 |
|------|------|--------|--------|
| `ui_notification` | title, body, level | 任意 | GlobalHUD |
| `possession_started` | entity | PossessionInterface | UI、Units、TimeManager |
| `possession_ended` | entity | PossessionInterface | UI、Units、TimeManager |
| `interior_entered` | building_id: int | Building | InputDispatcher、UI |
| `interior_exited` | building_id: int | Building | InputDispatcher、UI |
| `mega_interior_entered` | building_id: int, map_id: String | Building | GameRoot |
| `mega_interior_exited` | return_map_id: String | MegaInteriorMap | GameRoot |

### 2.7 其他

| 信号 | 参数 | 发射方 | 接收方 | 说明 |
|------|------|--------|--------|------|
| `balance_changed` | - | BalanceConfig | 订阅方 | 平衡配置热重载（预留，暂无消费方） |
| `debug_visibility_changed` | visible: bool | debug_gui | 生产模块调试标签 | 调试覆盖层显隐 |

---

## 三、EventBus 使用准则

1. **不循环发射**：A 发射信号触发 B，B 不能在做完后发射原信号回去
2. **参数不可变**：信号参数是快照副本
3. **单向事件流**：信号从数据层 → UI 层
4. **类型化发射**：直接用类型化 `.emit()` 发射（信号名拼写错误在编译期暴露），不做运行时存在性检查
5. **不预先占位**：未实现系统不提前声明信号；实现时按当时契约声明，并同步本文档与 `modules/README.md §9`
