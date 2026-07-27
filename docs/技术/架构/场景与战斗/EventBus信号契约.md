# EventBus 信号契约

> 拆分自 [场景与战斗架构.md](../场景与战斗架构.md) §十四。
> 关联文档：[`场景宿主架构.md`](场景宿主架构.md)、[`地图与场景图.md`](地图与场景图.md)、[`建筑与定居点.md`](建筑与定居点.md)、[`战斗与AI.md`](战斗与AI.md)、[`UI与环境.md`](UI与环境.md)、[`系统交互与EventBus.md`](../系统交互与EventBus.md)

---

## 十四、EventBus 新增信号

在 `core/autoload/event_bus.gd` 已有信号基础上，新增以下信号：

### 14.1 场景/地图事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `map_loaded` | map_id, map_type | SceneLoader | UI、Environment | 地图加载完成 |
| `map_unloaded` | map_id | SceneLoader | UI | 地图卸载 |
| `chunk_loaded` | chunk_idx | SceneLoader | MapInstance | Chunk 加载完成 |
| `chunk_unloaded` | chunk_idx | SceneLoader | MapInstance | Chunk 卸载 |
| `travel_started` | from_id, to_id, mode | SceneLoader | UI、WorldClock | 开始旅行 |
| `travel_completed` | to_id | SceneLoader | UI | 旅行完成 |

### 14.2 输入模式事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `input_mode_changed` | old_mode, new_mode | InputDispatcher | UI、Units | 模式切换 |
| `possession_started` | unit_id | PossessionInterface | UI、Units | 玩家附身 |
| `possession_ended` | unit_id | PossessionInterface | UI、Units | 退出附身 |

### 14.3 建筑事件（扩展）

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `building_placement_started` | building_def_id | PlacementSystem | UI | 进入选址模式 |
| `building_placement_confirmed` | building_def_id, cell_pos | PlacementSystem | Construction | 选址确认 |
| `building_placement_cancelled` | — | PlacementSystem | UI | 取消选址 |
| `interior_entered` | building_id | Building | InputDispatcher、UI | 进入室内交互区（透明化触发，[地图与场景图.md](地图与场景图.md) §5.2） |
| `interior_exited` | building_id | Building | InputDispatcher、UI | 离开室内交互区（[地图与场景图.md](地图与场景图.md) §5.2） |
| `mega_interior_entered` | building_id, map_id | Building | SceneLoader、UI | 传送进入大建筑（[地图与场景图.md](地图与场景图.md) §5.6） |
| `mega_interior_exited` | return_map_id | MegaInteriorMap | SceneLoader、UI | 从大建筑返回（[地图与场景图.md](地图与场景图.md) §5.6.2） |

### 14.4 战斗编队事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `selection_changed` | unit_ids: Array | SelectionSystem | UI | 框选/选择变化 |
| `squad_created` | squad_id, unit_ids | FormationSystem | UI、Organization | 编队创建 |
| `order_issued` | order_type, target_squad_id, issuer_unit_id | TacticalOrders | UI、Units | 下达号令 |
| `commander_assigned` | squad_id, unit_id | Organization | UI | 任命指挥官 |

### 14.5 环境事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `weather_changed` | old_weather, new_weather | WeatherSystem | UI、Audio | 天气切换 |
| `time_of_day_changed` | old_t, new_t | WorldClock | Environment | 时间推进 |
| `ground_shake` | intensity, duration | 任意 | Environment、Camera | 地面震动 |