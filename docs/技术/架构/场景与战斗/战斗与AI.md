# 战斗与AI

> 拆分自 [场景与战斗架构.md](../场景与战斗架构.md) §七、§八。
> 关联文档：[`场景宿主架构.md`](场景宿主架构.md)（InputDispatcher/CameraRig）、[`地图与场景图.md`](地图与场景图.md)（MapInstance/EntityHost）、[`事件总线信号契约.md`](EventBus信号契约.md)

---

## 七、火柴人行为 AI

### 7.1 StickmanEntity 节点结构（在已有 StickmanRig 之外包一层）

```
StickmanEntity (CharacterBody2D)        ← 物理+碰撞
├── StickmanRig (Skeleton2D)            ← ✅ 已有，纯渲染骨架
├── Hitbox (Area2D)                     ← 受击判定
├── WeaponMount (Node2D)                ← 武器挂载
├── HealthComponent (Node)              ← HP/士气
├── AIController (Node)                 ← 决策大脑
│   └── BehaviorStateMachine
└── PossessionInterface (Node)          ← 玩家附身接口
```

**关键**：`StickmanRig` 不动（已实现的 IK/动画保留），外层包一个 `CharacterBody2D` 承担物理与移动。AI 通过 `rig.play("walk")` + `rig.set_anim_speed(...)` 驱动渲染，通过 `CharacterBody2D.velocity` 驱动物理。

#### 7.1.1 地面约束（Y 范围 + X 边界）

火柴人可在地面区域内上下左右自由移动（不是锁死在 ground_y 一条线）：

```gdscript
# StickmanEntity 字段
var ground_y: float = 300.0       # 地面顶部 Y（由 MapInstance.spawn_entity 注入）
var ground_bottom: float = 1024.0 # 地面底部 Y（火柴人可走区域底部）
var map_left: float = 0.0         # X 活动范围左边界
var map_right: float = 2048.0     # X 活动范围右边界
var foot_offset: float = 30.0     # 脚部到节点原点的偏移（CollisionShape2D 半高）

func _physics_process(delta):
    # ... 输入处理（WASD 上下左右）...
    move_and_slide()
    # Y 范围约束：脚部保持在 [ground_y, ground_bottom] 内
    var y_min: float = ground_y - foot_offset
    var y_max: float = ground_bottom - foot_offset
    global_position.y = clampf(global_position.y, y_min, y_max)
    # X 边界约束
    global_position.x = clampf(global_position.x, map_left, map_right)
```

**生成位置：** 火柴人生成 Y = `ground_y + (ground_bottom - ground_y) * 0.5`（地面垂直范围偏中心）。

**未来扩展（非 P0）：**
- 跳跃：`velocity.y` 临时非零，落地后重新受 Y 范围约束
- 飞行单位：`position.y` 可超出 `ground_y`（向上飞），但仍受 `ground_bottom` 约束
- 地形高度变化：地图不同 X 位置 `ground_y` 不同（查表），火柴人 Y 跟随地形

#### 7.1.2 通行障碍系统（WalkBarrier + PassageBarrier）

火柴人移动除了受 `ground_y`/`ground_bottom`/`map_left`/`map_right` 矩形约束外，还受**两级透明障碍**约束：

**地图级 WalkBarrier（悬崖/高楼边缘）**：
- 位于 `MapInstance.WalkBarrier` 节点下，含若干 `Area2D` + `CollisionShape2D`（矩形）
- 设计时在地图场景中绘制，覆盖悬崖边缘/高楼边界/断崖
- 运行时不可见，调试模式显示为**蓝色半透明矩形**（详见 [UI与环境.md](UI与环境.md) §10.5）
- 适用场景：悬崖边缘、高楼堡垒边缘、断崖、任何"角色不能御空而行"的边界
- **不适用于山坡**（山坡走 `SlopeMap` 独立逻辑，详见 [地图与场景图.md](地图与场景图.md) §3.1）

**建筑级 PassageBarrier（建筑本体不可通行）**：
- 位于每个建筑场景的 `PassageBarrier` 子节点下（详见 [建筑与定居点.md](建筑与定居点.md) §4.3）
- 设计师在建筑场景中绘制，划定建筑本体哪些区域不可通行
- 运行时不可见，调试模式显示为**紫色半透明矩形**（与地图级蓝色区分）
- 典型用例：雕像上下可过、房屋只能从下方过、矿山完全不可过

**火柴人碰撞查询**：

```gdscript
# StickmanEntity._physics_process
var _last_valid_position: Vector2

func _physics_process(delta):
    # ... 输入处理 + move_and_slide() + Y/X 矩形约束 ...

    # 通行障碍检测：若进入任何 WalkBarrier / PassageBarrier 区域，回退到上一帧位置
    if _is_in_passage_barrier():
        global_position = _last_valid_position
        velocity = Vector2.ZERO  # 撞墙停止
    else:
        _last_valid_position = global_position

func _is_in_passage_barrier() -> bool:
    # 查询当前 MapInstance.WalkBarrier 下所有 Area2D
    # 查询 BuildingHost 下所有建筑的 PassageBarrier Area2D
    # 用 PhysicsDirectSpaceState2D.intersect_point 或 Area2D.overlaps_body 检测
    # 实现细节：见 modules/units/scripts/stickman_entity.gd
    ...
```

**与 SlopeMap 的关系**：
- WalkBarrier/PassageBarrier 是"矩形区域阻挡"的轻量方案，适用于 VillageMap 等水平卷轴地图
- SlopeMap 走独立逻辑，不用 WalkBarrier（坡面是连续的 Y 变化，不是矩形阻挡）

**火柴人之间的碰撞**：
- `StickmanEntity` 的 `collision_layer = 2`，`collision_mask = 3`（layer 1 + layer 2）
- 火柴人与地形障碍（layer 1）和其他火柴人（layer 2）都会发生物理碰撞
- 工地临时障碍（建造中）挂在 `WalkBarrier` 下，与建筑完工后的 `PassageBarrier` 使用完全相同的 size/position（从建筑场景模板读取），确保障碍切换无缝

**寻路避障（方案已定 2026-08：局部避障 + 简单 A\*）**：
- 当前火柴人直线走向目标，遇到障碍被硬弹回，在障碍边缘卡死（待实现）
- 方案：平时**局部避障（raycast + 切线滑动 + separation 分离）**，契合模拟 Tag / RimWorld pawn 移动模型；障碍复杂/密集时用**简单 A\* 网格**兜底，两者结合
- 详见 `docs/项目/P0收口执行计划.md` §13.4

#### 7.1.3 附身接口

`PossessionInterface` 提供：
- `set_possessed(bool)`：切换玩家控制
- `is_possessed() -> bool`
- 附身时：读取 WASD 输入驱动 `velocity`，`AIController` 暂停
- 取消附身：`AIController` 恢复控制

### 7.2 行为状态机

```
modules/units/ai/（✅=已实现注册，📋=设计未实现）
├── behavior_base.gd                 ✅ 行为基类（enter/update/exit）
├── behavior_idle.gd                 ✅ 闲置（默认空闲，P0 原地待机）
├── behavior_wander.gd               ✅ 漫游（P0 默认关闭 WANDER_PROBABILITY=0，仅显式调用）
├── behavior_move.gd                 ✅ 移动（含简单寻路）
├── behavior_follow.gd               ✅ 跟随（小队"跟随玩家"）
├── behavior_attack.gd               ✅ 攻击（命中帧→伤害事件）
├── behavior_seek_cover.gd           ✅ 找掩体
├── behavior_retreat.gd              ✅ 撤退（当前亦承担溃逃）
├── behavior_work.gd                 ✅ 建造（build 动画驱动，受材料进度限制）
├── behavior_haul.gd                 ✅ 搬运（仓库↔工地往返）
├── behavior_suppress.gd             📋 火力压制（设计未实现）
├── behavior_flank.gd                📋 侧翼包抄（设计未实现）
├── behavior_flee.gd                 📋 独立溃逃（设计未实现，暂由 retreat 承担）
└── behavior_state_machine.gd        ✅ 状态机调度
```

每个行为是独立的 `Node`/`Resource`，状态机持有引用并通过 `travel(behavior_name)` 切换。

#### 7.2.0 搬运与建造行为

**双进度系统**：建造项目有两个进度条：
- **材料进度** `[0,1]`：由搬运工交付推进，每次 `deliver_material()` +25%（4次填满）
- **建造进度** `current_work / total_work`：由建造工敲击推进，受材料限制（建造 ≤ 材料）

**AIController 决策逻辑**：
- `needs_material()` 且有仓库 → `travel("haul", {project})`
- 否则 → `travel("work", {project})`
- 多工人各自决策，不限制搬运工数量

**behavior_haul 搬运行为**：
- 阶段：TO_WAREHOUSE → PICKING(0.5s) → TO_SITE → DELIVERING(0.5s) → 循环/finish
- 目标点站在 PassageBarrier 外 40px（`STANDOFF_X`），不走进建筑
- 取货时 `set_carrying(true)` 切 walk_carry 动画，交付时 `set_carrying(false)`
- `is_finished()` 早退防止 finish 后重复交付

**behavior_work 建造行为**：
- 到达工地障碍外后播放 build 动画，每次循环完成（1.8s）推进 `total_work / 8`
- 材料耗尽时 `finish()` 转 haul，形成 work↔haul 循环

**站位规则**：
- 工人和搬运工都站在 PassageBarrier 外 `STANDOFF_X=40px` 处
- 多名工人按 `slot_index` 沿障碍外侧分散，避免重叠

**walk_carry 动画**：
- `walk_carry.tres` = walk.tres 腿部/身躯轨道 + 搬运手部姿势单帧
- 工具脚本 `tools/animation/generate_walk_carry.gd` 可重新生成

#### 7.2.1 待机行为修正（创始人确认）

> **设计决策**：火柴人无事可做时**原地播放待机动画**，不随机跑动。

当前 `behavior_wander.gd` 实现的是 Reynolds Steering 随机漫游行为（含卡住检测、掉头恢复）。创始人确认：**火柴人空闲时应原地待机**，不应随机游走。

**改动**：
- `behavior_idle` 为主空闲行为：原地播放 idle 动画，偶尔播放小动作（看四周、伸懒腰等）
- `behavior_wander` 降级为**特定场景触发**（如村民在集市闲逛、士兵巡逻），不是默认空闲行为
- AIController 无任务时默认切到 `behavior_idle`，不切到 `behavior_wander`

#### 7.2.2 个体属性标签系统（创始人确认，参考《世界盒子》）

> **设计决策**：每个火柴人有独立属性标签，影响行为树和适合的工作。

**三层架构**（参考世界盒子的"特质 -> 神经元 -> 行为"模型）：

| 层 | 职责 | 说明 |
|----|------|------|
| **特质层** | 火柴人先天属性标签 | 力量/智力/敏捷/工艺/指挥等，影响数值上限和行为权重 |
| **决策层** | 属性向行为决策添加权重 | 高力量增加"攻击/采石"权重，高智力增加"研究/管理"权重 |
| **行为层** | BehaviorStateMachine 根据权重选择行为 | 已有状态机框架，扩展权重计算 |

**与现有系统的关系**：
- `StickmanState` 新增 `traits: Dictionary` 字段（属性标签 -> 数值）
- `AIController` 在行为决策时读取 traits，调整行为切换权重
- `WorkCrewAssigner` 派工时参考 traits（高工艺 -> 建造工，高力量 -> 搬运工/采石工）
- 装备系统影响 traits（武器加攻击，工具加采集效率）

**迭代路线**：
- P0：四属性（**力量/智力/敏捷/工艺**），取值 **1-10 默认 3**，简单权重影响（高力量→攻击/搬运权重↑，高智力→研究/管理↑，高工艺→建造/采集↑）
- P1：扩展属性种类 + 装备系统 + 职业分化 + **天赋树**（承接 traits，树状解锁）
- P2+：亚种/文化/宗教等世界盒子式复杂特质（详见 [竞品分析.md](../../../商业/竞品分析.md) §4.12）

### 7.3 三层命令系统（决策来源）

```
┌──────────────────────────────────────┐
│ 1. 玩家/指挥链下达的指令              │ ← 高优先级
│    (tactical_orders → command_chain) │
├──────────────────────────────────────┤
│ 2. 编制默认战术（自主决策权限内）     │ ← 中优先级
│    (OrganizationState.autonomy_level)│
├──────────────────────────────────────┤
│ 3. 单位本能（受击反击、找掩体）       │ ← 低优先级
│    (behavior_xxx 内置触发)           │
└──────────────────────────────────────┘
```

- 高优先级指令覆盖中低优先级
- 中优先级在无指令时驱动默认行为
- 低优先级是生存本能，永远生效但被高优先级压制

`StickmanState` 已有 `autonomy_level` 字段，AIController 读取它决定能否自主行动。

> **实现状态（2026-08）**：当前为**确定性优先级**（命令覆盖 > 战斗 > 跟随 > work > idle），见 `ai_controller.gd _make_decision`；§7.4 灵动性（概率钩子 + 战场导演情绪标签）为 **P1 目标，未实现**。决策优先级当前**硬编码**，计划抽成 `.tres` 数据驱动。

### 7.4 小兵步枪式灵动性 — 两层实现

**第一层：行为层概率钩子**

每个战斗行为内置可配置概率：
```gdscript
# behavior_attack.gd 示意
@export var prob_aggressive_push: float = 0.05  # 擅自冲锋概率
@export var prob_hesitate: float = 0.03          # 犹豫概率

func update(delta):
    if _is_at_disadvantage() and randf() < prob_hesitate:
        _enter_hesitate_substate()
    elif _enemy_exposed() and randf() < prob_aggressive_push:
        _push_forward()
```

**第二层：战场导演情绪标签**

`battle_ai_director.gd` 周期性（每 2~5s）给单位打"情绪标签"：
- `HESITANT` — 犹豫（命中率-30%、移动减速）
- `EXCITED` — 亢奋（追击倾向+50%、忽视指令概率+10%）
- `PANICKED` — 恐慌（找掩体优先级最高、可能溃逃）
- `STEADY` — 稳定（默认）

情绪概率受：指挥官能力、部队士气、文化传统、自主决策权限影响。

### 7.5 玩家附身

`PossessionInterface`：
```gdscript
func possess(unit_id: int) -> void:
    # 1. 暂停该单位的 AIController
    # 2. InputDispatcher.set_mode(POSSESS)
    # 3. CameraRig.follow(entity)
    # 4. 路由 WASD/鼠标到该 entity 的 velocity/weapon

func release() -> void:
    # 反向恢复
```

附身时：
- WASD → `CharacterBody2D.velocity`
- 鼠标左键 → 攻击
- 鼠标右键 → 瞄准/格挡
- Tab → 打开该层级管理面板
- ESC → 退出附身

---

## 八、战斗系统

### 8.1 战斗实例 vs 战场场景（关键解耦）

```
battle_instance.gd (纯逻辑)         ← 战斗状态、参战双方、结果判定
   ↓ 拥有
battle_arena.tscn (战场场景)         ← 渲染战场、地形、掩体
   ↓ 引用
多个 StickmanEntity                  ← 参战单位
```

**为什么这样**：城镇被袭变战场时，**不切场景**——当前 `VillageMap` 挂载一个 `battle_instance` 即可，建筑继续显示（且可被破坏）。`battle_instance` 是纯数据+逻辑，挂在任何 Map 上都行。

`MapInstance.BattleAnchor` 节点就是 `battle_instance` 的挂载点。无战斗时为空。

### 8.2 模块结构

```
modules/combat/
├── api.gd
├── scripts/
│   ├── battle_manager.gd           # 多战场调度（同时打几场）
│   ├── battle_instance.gd          # 单场战斗逻辑（不依赖场景）
│   ├── formation_system.gd         # 编队/框选/分组
│   ├── tactical_orders.gd          # 预设号令（前进/冲刺/掩护/撤退）
│   ├── command_chain.gd            # 指挥链（逐层下达+延迟）
│   ├── morale_system.gd            # 士气（影响AI行为选择）
│   ├── cover_system.gd             # 掩体（查询接口供AI调用）
│   ├── suppression_system.gd       # 火力压制（区域debuff）
│   └── battle_ai_director.gd       # 战场导演（灵动性来源）
├── scenes/
│   ├── battlefield_chunk.tscn      # 战场chunk（用于BattlefieldMap）
│   └── battle_overlay.tscn         # 战斗UI层（指令面板、选中框）
└── data/
    └── tactical_presets.tres       # 预设号令配置
```

### 8.3 框选 → 编队 → 任命 → 下令 流程

```
1. 玩家框选 → selection_system 返回 unit_ids 数组
2. 打开编制窗口（GlobalHUD"编制"按钮 / BattlePanel"打开编制窗口"）
   → 选预设（战斗班/建造队/工人队）+ 勾选空闲火柴人 → formation_system.create_squad(units, name, preset_id)
   → 创建 L1 组织（tag 来自预设）+ 成员角色写入 + 职责范围（work_types）记录
3. "任命排长"→ formation_system.assign_leader(squad_id, leader_unit)
4. "全体前进"→ tactical_orders.issue(ORDER_ADVANCE_ALL, target_pos)
            → command_chain 逐层下达（带延迟）
            → 各单位 AIController 接收 → 切换到 behavior_move
5. "对排长发令"→ selection 排长 → tactical_orders.issue_to(squad_id, ORDER_*)
              → 仅该 squad 执行
```

**队伍类型编制**（2026-08 新增）：编队 = 编制预设实例。预设（`config/formations/formation_presets.tres`）定义组织标签 + 职责范围（RimWorld 式工作类型 WORK_COMBAT/WORK_BUILD/WORK_HAUL/WORK_FORAGE）+ 成员角色。职责范围可调整（`set_squad_work_types`）；AI 决策与号令按职责过滤——战斗班可战斗接号令、建造队可建造/搬运不参战、工人队可搬运/采集。未编队单位全能（保持原行为）。组织系统 VALID_TAGS 追加 LABOR。

**关键**：任命排长 = 创建 L1 组织节点，复用现有 `organization_state.gd`。这就是为什么战斗和组织高度耦合——必须一起设计。

**带队出征（跨图携带，2026-08 新增）**：编队可随玩家跨图——`SceneLoader.travel_started`（旧图卸载前）→ `FormationSystem.export_squads` 快照 + `disband_all_squads` 清理 → 新图 `_on_map_loaded` spawn 跟随者（玩家右侧排开）+ `restore_squads` 重建（preset/职责/排长/角色）。遭遇战战场（battlefield）由此支持"队伍 vs 敌人"（玩家+随行 vs 4 敌，全灭收敛）。

### 8.4 预设号令清单（P0 范围）

| 号令 | 效果 | 适用层级 |
|------|------|---------|
| `ORDER_ADVANCE_ALL` | 全体向目标点前进 | L1-L2 |
| `ORDER_SPRINT` | 消耗体力加速冲刺 | L1 |
| `ORDER_HOLD_POSITION` | 原地坚守 | L1-L2 |
| `ORDER_RETREAT` | 有序后撤 | L1-L2 |
| `ORDER_TAKE_COVER` | 就近找掩体 | L1 |
| `ORDER_SUPPRESSING_FIRE` | 对指定区域压制射击 | L1 |
| `ORDER_FLANK_LEFT/RIGHT` | 侧翼包抄 | L1-L2 |
| `ORDER_RALLY` | 集结溃兵 | L2 |

### 8.5 指挥链延迟

命令从 L(n) 下达到 L(n-1) 有延迟，模拟传令时间：
- 延迟 = `base_delay × tier_diff × commander_efficiency_modifier`
- 默认 `base_delay = 2s`，每跨一层 +2s
- 指挥官能力高 → 延迟减半
- 玩家附身该层级指挥官时 → 延迟为 0（直接指挥）