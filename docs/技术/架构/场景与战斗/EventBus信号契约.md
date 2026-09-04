# EventBus 信号契约

> 拆分自 [场景与战斗架构.md](../场景与战斗架构.md) §十四。
> 关联文档：[`场景宿主架构.md`](场景宿主架构.md)、[`地图与场景图.md`](地图与场景图.md)、[`建筑与定居点.md`](建筑与定居点.md)、[`战斗与AI.md`](战斗与AI.md)、[`UI.md`](UI.md)、[`系统交互与EventBus.md`](../系统交互与EventBus.md)
>
> **真相源是 `core/autoload/event_bus.gd`**。未实现系统（天气/选址等）不预先占位信号，实现时按当时契约声明并同步本文档。

---

## 十四、场景与战斗相关信号

### 14.1 场景/地图事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `map_loaded` | map_id, map_type | SceneLoader | UI、Environment | 地图加载完成 |
| `map_unloaded` | map_id | SceneLoader | UI | 地图卸载 |
| `chunk_loaded` | chunk_idx | SceneLoader | MapInstance | Chunk 加载完成 |
| `chunk_unloaded` | chunk_idx | SceneLoader | MapInstance | Chunk 卸载 |
| `travel_started` | from_id, to_id, mode | SceneLoader | UI、WorldClock | 开始旅行 |
| `travel_completed` | to_id | SceneLoader | UI | 旅行完成 |

### 14.2 输入模式/附身事件

> 模式切换走 InputDispatcher 本地信号 `mode_changed(old_mode, new_mode)`（装配时注入连接），不进 EventBus。

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `possession_started` | entity | PossessionInterface | UI、Units、TimeManager | 玩家附身 |
| `possession_ended` | entity | PossessionInterface | UI、Units、TimeManager | 退出附身 |

### 14.3 建筑/室内事件

> 建筑开工/完工/拆除/受损/升级信号由 construction/api.gd 自建（参数 `building_id, region_id`），不进 EventBus。

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `interior_entered` | building_id | Building | InputDispatcher、UI | 进入室内交互区（透明化触发，[地图与场景图.md](地图与场景图.md) §5.2） |
| `interior_exited` | building_id | Building | InputDispatcher、UI | 离开室内交互区（[地图与场景图.md](地图与场景图.md) §5.2） |
| `mega_interior_entered` | building_id, map_id | Building | GameRoot | 传送进入大建筑（[地图与场景图.md](地图与场景图.md) §5.6） |
| `mega_interior_exited` | return_map_id | MegaInteriorMap | GameRoot | 从大建筑返回（[地图与场景图.md](地图与场景图.md) §5.6.2） |

### 14.4 战斗编队事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `battle_started` | battle_id | BattleDirector | UI | 战斗开始 |
| `battle_ended` | battle_id, victory | BattleDirector | UI | 战斗结束 |
| `selection_changed` | unit_ids: Array | SelectionSystem | UI | 框选/选择变化 |
| `squad_created` | squad_id, unit_ids | FormationSystem | UI、Organization | 编队创建 |
| `order_issued` | order_type, target_squad_id, source_tier | TacticalOrders | UI、Units | 下达号令（source_tier=发令层级，0=玩家直接指挥） |
| `commander_assigned` | squad_id, unit_id | FormationSystem | UI | 任命指挥官 |
