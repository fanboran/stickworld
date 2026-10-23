# EventBus 信号契约

> 拆分自 [场景与战斗架构.md](../场景与战斗/场景与战斗架构.md) §十四。
> 关联文档：[`场景宿主架构.md`](场景宿主架构.md)、[`地图与场景图.md`](地图与场景图.md)、[`建筑与聚落.md`](建筑与聚落.md)、[`战斗与AI.md`](战斗与AI.md)、[`UI.md`](UI.md)、[`系统交互与EventBus.md`](../数据与契约/系统交互与EventBus.md)
>
> **真相源是 `core/autoload/event_bus.gd`**（现行 37 个信号，以该文件实声明为准；全量目录见 [系统交互与EventBus.md](../数据与契约/系统交互与EventBus.md)）。本文件收录场景与战斗域信号并记域内细节，其余信号（生命周期/指挥中继/领地归属等）归全量目录。未实现系统（天气/选址等）不预先占位信号，实现时按当时契约声明并同步两份文档。

---

## 十四、场景与战斗相关信号

### 14.1 场景/地图事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `travel_requested` | map_id, travel_mode | world_map（api.gd：聚落点击 / 道路场景首段） | SceneLoader | 玩家点击聚落进入场景图 |
| `map_loaded` | map_id, map_type | SceneLoader（本地信号后经 `_emit_event_bus` 字符串转发） | UI、Environment、MusicDirector | 地图加载完成 |
| `map_unloaded` | map_id | SceneLoader（同上转发） | UI、MusicDirector | 地图卸载 |
| `travel_started` | from_id, to_id, mode | SceneLoader（同上转发） | UI、WorldClock、MusicDirector | 开始旅行 |
| `travel_completed` | to_id | SceneLoader（同上转发） | UI | 旅行完成 |
| `strategic_map_opened` | - | world_map（strategic_map_controller） | UI、InputDispatcher、MusicDirector | 战略图打开 |
| `strategic_map_closed` | - | world_map（strategic_map_controller / l3_map_controller） | UI、InputDispatcher、MusicDirector | 战略图关闭 |
| `strategic_map_level_requested` | level（"L1"/"L2"/"L3"） | world_map L3 层级指示器（l3_zoom_indicator，HUD 层级按钮） | 装配方（system_setup_strategic_map，统一分派视图互斥与场景图输入暂停） | 战略图层级切换请求 |

> Chunk 加载/卸载不经 EventBus：走 `scene_loader.gd` 自带 `chunk_loaded/chunk_unloaded` 信号（chunk 流式为预留接口，生产消费方连本地信号）。

### 14.2 输入模式/接管事件

> 模式切换走 InputDispatcher 本地信号 `mode_changed(old_mode, new_mode)`（装配时注入连接），不进 EventBus。

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `user_control_started` | entity | UserControlInterface | UI、Units、TimeManager | 玩家接管 |
| `user_control_ended` | entity | UserControlInterface | UI、Units、TimeManager | 退出接管 |

### 14.3 建筑/室内事件

> 建筑开工/完工/拆除/受损/升级信号由 construction/api.gd 自建（参数 `building_id, region_id`），不进 EventBus。

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `interior_entered` | building_id | Building | InputDispatcher（player_control）、MusicDirector（室内情境） | 进入室内交互区（透明化触发，[地图与场景图.md](地图与场景图.md) §5.2） |
| `interior_exited` | building_id | Building | travel_handler（world，退房处理）、MusicDirector（情境回退） | 离开室内交互区（[地图与场景图.md](地图与场景图.md) §5.2） |
| `mega_interior_entered` | building_id, map_id | Building（TELEPORT 模式，EnterTrigger） | MusicDirector（情境回退） | 传送进入大建筑——旧 2D 图接收链（GameRoot 校验+过场+旅行）随 mega_interior 图清退拆除，信号保留待室内 v3（[地图与场景图.md](地图与场景图.md) §5.6） |

### 14.4 战斗编队事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|---------|
| `battle_started` | battle_id | BattleInstance（combat，start()） | UI（全局 HUD、战斗横幅）、TimeManager（开战自动暂停）、AudioManager（SFX）、MusicDirector（战斗声场）、world_map api（战斗中标志） | 战斗开始 |
| `battle_ended` | battle_id, victory | BattleInstance（combat，_end()） | 同 `battle_started`（随 victory 收声/解暂停/恢复快速旅行） | 战斗结束 |
| `battle_settled` | battle_id, summary: Dictionary | BattleInstance._end（先于 `battle_ended` 发射） | 测试断言（结算套件、RL env、dev 场景）；生产订户暂无 | 战斗结算载荷先到、胜负随后；summary 携带 result/reason/duration/player_wins/player_faction/casualties/alive，监听方不必回查已 queue_free 的 BattleInstance |
| `battle_engagement_changed` | battle_id, alive_units: int | BattleInstance（start() 先发初值 / _physics_tick 低频广播） | MusicDirector（战斗声场规模档）、测试 | 战场规模脉动：alive_units = 双方存活总数；battle_ended 即战场消亡，不发 0 |
| `team_ai_stance_changed` | battle_id, faction, from_stance, to_stance, reason | TeamAi（宿主 _set_stance） | 调试 HUD（combat `team_ai_hud.gd`，DebugApi drawer F3 显隐）、测试断言 | 阵营 AI 姿态切换（0=GARRISON/1=DEFEND/2=ATTACK，对齐 dump Team.Stance 枚举序） |
| `selection_changed` | unit_ids: Array | SelectionSystem | UI | 框选/选择变化 |
| `squad_created` | squad_id, unit_ids | FormationSystem | UI、Organization | 编队创建 |
| `order_issued` | order_type, target_squad_id, source_tier | TacticalOrders | UI、Units | 下达号令。两条路径共用：`issue`（target=L1 小队 id，现场指挥零延迟）与 `issue_to_org`（target=组织根 id，逐层传播接力）——target 字段按下达路径分别为 squad_id / org_id（3-F2） |
| `commander_assigned` | squad_id, unit_id | FormationSystem、organization 补位引擎 | UI、FormationSystem | 任命指挥官（ FormationSystem.assign_leader）与组织侧伤亡补位成功（manager 内聚触发）都会发射；FormationSystem 订阅回写 squad.leader（排长 UI/光环自动恢复，3-F2） |
| `ai_behavior_switched` | entity, from_behavior, to_behavior, params | BehaviorStateMachine.travel（唯一入口埋点） | AI 决策观察窗（modules/debug_gui）、测试断言 | 单位行为切换。每次切换必发（决策层/号令/看门狗/打通态全路径），无订户零成本；切换原因由观测侧在信号时点结合 AIController 状态推断（瞬时态事后不可考） |
