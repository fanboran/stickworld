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
| 战斗->资源 | 部分 | 战胜缴获✅；战斗物资消耗未实现——弹药待接线，无食物消耗端且食物已废 |
| 战斗->扩张 | ✅ | 战胜->获得地块控制度 |
| 运输->战斗 | ✅ | 运输断供->前线物/人不在场（无弹转肉搏、缺员无法回补——物理事实，见 物流系统 §3.1） |
| 科技->组织 | ✅ | 科技解锁新的编制类型/组织能力 |
| 资源->科技 | ✅ | 科研消耗资源（纸/墨/实验材料；法系材料方向为液态法力） |
| 建设->运输 | ✅ | 修路->运输效率提升 |
| 经营建设->一切 | ✅ | 经营建设是所有循环的起点和终点 |

---

## 二、EventBus 事件目录（现行）

> 与 `core/autoload/event_bus.gd` 逐条对齐（信号数以该文件实声明为准）。

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
| 资源 | `resource_changed` / `resource_not_enough` / `price_changed`（resources/api.gd） | resource_id, ...（旧市场模型信号，随经济重做重审） |
| 建筑 | `building_completed` / `building_removed`（construction/api.gd） | building_id: String, region_id: String |
| 建筑 | `building_damaged`（construction/api.gd） | building_id: String, damage_amount: float |
| 建筑 | `building_upgraded`（construction/api.gd） | building_id: String, old_tier: int, new_tier: int |
| 建筑 | `building_repaired`（construction/api.gd） | building_id: String |
| 组织 | `org_created` / `org_restructured` / `org_disbanded`（organization/api.gd） | org_id: String |
| 组织 | `report_filed`（organization/api.gd） | org_id: String, report: Dictionary（战斗域三类事件经 squad_report_hooks 落信号，strategic_overview_panel 消费） |

### 2.3 战斗事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `battle_started` | battle_id: String | BattleInstance（combat） | UI（全局 HUD、战斗横幅）、TimeManager（开战自动暂停）、AudioManager（SFX）、MusicDirector（战斗声场）、world_map api（战斗中标志） | 战斗开始 |
| `battle_ended` | battle_id: String, victory: bool | BattleInstance（combat） | 同 `battle_started`（随 victory 收声/解暂停/恢复快速旅行） | 战斗结束 |
| `battle_settled` | battle_id: String, summary: Dictionary | BattleInstance._end（先于 `battle_ended` 发射：结算数据先到，胜负随后） | 测试断言（结算套件、RL env、dev 场景）；生产订户暂无 | 战斗结算载荷；summary 携带 result/reason/duration/player_wins/player_faction/casualties/alive，监听方不必回查已 queue_free 的 BattleInstance |
| `battle_engagement_changed` | battle_id: String, alive_units: int | BattleInstance.start / _physics_tick | MusicDirector（战斗声场规模档）、测试 | 战场规模脉动：alive_units = 双方存活总数，随胜负清点同拍（0.5s）低频广播，start() 先发初值；battle_ended 即收声不发 0 |
| `team_ai_stance_changed` | battle_id: String, faction: int, from_stance: int, to_stance: int, reason: String | TeamAi（宿主 _set_stance） | 调试 HUD（combat `team_ai_hud.gd`，DebugApi drawer F3 显隐）、测试断言 | 阵营 AI 姿态切换（0=GARRISON/1=DEFEND/2=ATTACK） |
| `ai_behavior_switched` | entity, from_behavior: String, to_behavior: String, params: Dictionary | BehaviorStateMachine.travel（唯一入口埋点） | AI 决策观察窗（debug_gui `ai_viz_window.gd`）、测试断言 | 单位行为状态机切换（每次切换必发——号令/看门狗/决策层全路径；params 为诊断上下文只读） |

### 2.4 编队事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `selection_changed` | unit_ids: Array | SelectionSystem | UI | 框选变化 |
| `squad_created` | squad_id: String, unit_ids: Array | FormationSystem | UI、Organization | 编队创建 |
| `order_issued` | order_type: int, target_squad_id: String, source_tier: int | TacticalOrders | UI、Units | 号令下达（source_tier=发令层级，0=玩家直接指挥） |
| `commander_assigned` | squad_id: String, unit_id: int | FormationSystem | UI | 任命指挥官 |

### 2.5 指挥中继事件

> combat 域 CommandChain 逐跳接力信号的 EventBus 镜像（command_chain.gd 发射本地信号后原样转发，链逻辑不变）；消费方是 organization 的指挥链视图，走 EventBus 免跨模块取节点。

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `relay_started` | relay_id: String, order_type: int, from_org: String, to_org: String, hop_index: int, eta: float | CommandChain（combat，本地信号镜像转发） | organization 指挥链视图（command_chain_view 订阅 → command_chain_board）、测试 | 命令单跳起跑；eta = 本跳传输层传播秒数（hop 0 = 玩家跳） |
| `relay_arrived` | relay_id: String, order_type: int, from_org: String, to_org: String, hop_index: int, outcome: String | CommandChain（combat，同上镜像） | organization 指挥链视图、测试 | 单跳抵达/停驻结局；outcome ∈ {delivered, relayed, rejected_noncombat, dropped_leaderless, dropped_invalid, dropped_no_squad, dropped_no_formation} |

### 2.6 场景/地图/旅行/战略图事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `travel_requested` | map_id: String, travel_mode: int | world_map（api.gd：聚落点击 / 道路场景首段） | SceneLoader | 玩家点击聚落进入场景图 |
| `map_loaded` | map_id: String, map_type: int | SceneLoader | UI / Environment / MusicDirector | 地图加载完成 |
| `map_unloaded` | map_id: String | SceneLoader | UI / MusicDirector | 地图卸载完成 |
| `travel_started` | from_id, to_id, mode: int | SceneLoader | UI / WorldClock / MusicDirector | 旅行开始 |
| `travel_completed` | to_id: String | SceneLoader | UI | 旅行完成 |
| `strategic_map_opened` | - | world_map | UI / InputDispatcher / MusicDirector | 战略图打开 |
| `strategic_map_closed` | - | world_map | UI / InputDispatcher / MusicDirector | 战略图关闭 |
| `strategic_map_level_requested` | level: String | world_map L3 层级指示器（l3_zoom_indicator，HUD 层级按钮） | 装配方（system_setup_strategic_map，统一分派视图互斥与场景图输入暂停） | 战略图层级切换请求（"L1" 本省地块 / "L2" 地区 / "L3" 大世界） |
| `settlement_updated` | settlement_id: String, population_score: float | 暂无发射方（全仓零 emit） | world_map api（订阅更新聚落规模 + L1 视图 blob 单城重算） | 聚落规模变化触发建成区 blob 重算（建设系统接线前为死订阅） |

### 2.7 领地归属 / 解锁事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `region_owner_changed` | region_id: String, new_owner: String | 世界模型政权归属变更（尚未接入；接入前测试可代发驱动染色管道） | 战略图（world_map/api.gd，唯一订阅方：累积归属表 → 重取已占地块表 → 政治模式逐格染色） | 地块政权归属变更；region_id 发 tile 级 id（归属最小单位是 tile，契约见世界地图数据流） |
| `unlock_granted` | unlock_id: String | 待世界模型接入 | 建筑可建集门禁（`ConstructionManager.is_def_unlocked` × `WorldState.unlocks` 判定，BuildMenu 随信号重刷）、测试 | 解锁项发放（预留装备/科技等系统按需接线） |

### 2.8 UI / 接管 / 室内事件

| 信号 | 参数 | 发射方 | 接收方 |
|------|------|--------|--------|
| `ui_notification` | title, body, level | 任意 | GlobalHUD |
| `user_control_started` | entity | UserControlInterface | UI、Units、TimeManager |
| `user_control_ended` | entity | UserControlInterface | UI、Units、TimeManager |
| `interior_entered` | building_id: int | Building | InputDispatcher（player_control）、MusicDirector（室内情境） |
| `interior_exited` | building_id: int | Building | travel_handler（world，退房处理）、MusicDirector（情境回退） |
| `mega_interior_entered` | building_id: int, map_id: String | Building | MusicDirector（情境回退）；传送链随 mega_interior 图清退拆除，信号保留待室内 v3 |

### 2.9 其他

| 信号 | 参数 | 发射方 | 接收方 | 说明 |
|------|------|--------|--------|------|
| `balance_changed` | - | BalanceConfig（加载/热重载完成时） | organization `default_behavior_writer.gd`（热重载回读档案总闸）、测试 | 平衡配置变更 |
| `debug_visibility_changed` | visible: bool | debug_gui | 生产模块调试标签 | 调试覆盖层显隐 |

---

## 三、EventBus 使用准则

1. **不循环发射**：A 发射信号触发 B，B 不能在做完后发射原信号回去
2. **参数不可变**：信号参数是快照副本
3. **单向事件流**：信号从数据层 → UI 层
4. **类型化发射**：直接用类型化 `.emit()` 发射（信号名拼写错误在编译期暴露），不做运行时存在性检查
5. **不预先占位**：未实现系统不提前声明信号；实现时按当时契约声明，并同步本文档与 `modules/README.md §9`
