# 战斗与AI

> 拆分自 [场景与战斗架构.md](../场景与战斗/场景与战斗架构.md) §七、§八。
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

#### 7.1.0 骨架 IK 已知坑（TwoBoneIK joint idx 与骨链强耦合）

StickmanRig 的 TwoBoneIK 修改器有两层强约束，破坏任意一层都会出现**全身渲染横躺 ~90°** 而骨骼 `global_transform` 打印直立的诡异表现：

- **tscn 里写死的 `joint_one/two_bone_idx` 是历史值**，只有 NodePath（如 `hip/spine_root/thigh_outer`）在运行时解析成功时才会被 `_init_ik` 按骨名校正。骨链重排后若不同步更新 NodePath，残留 idx 会指向别的骨（idx 0 = 根骨 hip）——腿 IK 拽根骨 = 全身横躺。
- **"打印直立、渲染横躺"是引擎机制**：Skeleton2D 修改器在骨架内部 process 阶段以 local_pose_override 写入渲染变换，常规 process 阶段从 cache_transform 还原（非持久 override）——常规阶段采样 `global_transform` 永远是未解算的直立值，渲染看到的才是 override 后姿态。排查时不要相信常规 process 期的打印。

防护：`_init_ik` 对 NodePath 解析失败的修改器整条移除（防残留 idx 劫持）。最小复现/对照工具：`tools/baking/diag_entity_pose_root.tscn`（实体 / 裸骨架 / 无 IK 三探针 + 像素包围盒判定）；完整根因链见 `tools/baking/render_weapon_check.gd` 头注释。

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
- 运行时不可见，调试模式显示为**蓝色半透明矩形**（详见 [UI.md](UI.md) §10.5）
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
modules/units/scripts/ai/（✅=已实现注册，📋=设计未实现）
├── behavior_base.gd                 ✅ 行为基类（enter/update/exit）
├── behavior_idle.gd                 ✅ 闲置（默认空闲，P0 原地待机）
├── behavior_wander.gd               ✅ 漫游（P0 默认关闭 WANDER_PROBABILITY=0，仅显式调用）
├── behavior_move.gd                 ✅ 移动（含简单寻路）
├── behavior_follow.gd               ✅ 跟随（小队"跟随玩家"）
├── behavior_attack.gd               ✅ 攻击（命中帧→伤害事件）
├── behavior_seek_cover.gd           ✅ 找掩体
├── behavior_retreat.gd              ✅ 撤退/避战（fallback 档=避战：RA 压制式脱离，不走向地图边缘）
├── behavior_work.gd                 ✅ 建造（build 动画驱动，受材料进度限制）
├── behavior_haul.gd                 ✅ 搬运（仓库↔工地往返）
├── behavior_suppress.gd             📋 火力压制（设计未实现）
├── behavior_flank.gd                📋 侧翼包抄（设计未实现）
├── behavior_flee.gd                 📋 独立溃逃（已随裁决【删溃逃、立避战】取消立项——溃逃永久退役，避战由 retreat fallback 档承担）
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

#### 7.2.3 遇阻接战（局部绕行 + 打通，不做 A*）

移动执行（behavior_move）途中的敌挡路处置，创始人口径：「前往任务目标的路上如果被
敌人拦住且无法简单绕过，就像一般 RTS 一样攻击路径上的敌人」。寻路 = 局部绕行 +
遇阻接战的组合；**命令有粘性**：接战拦路者是号令的临时插叙，任务持续执行到完成或
失效，不高频翻改。

- **挡路判定**：前进锥面扫描（口径同 entity_motion 友军让路 `_ally_yield_lateral`：
  前向点积 > YIELD_AHEAD_DOT，敌我区分），挡路判定距离 180px
  【提案/待定·待实测校准】。与"接敌即战"（engage_in_range）共用 0.2s 节流拍，
  挡路处置优先——路径上的敌人不走"接敌即战 finish 清令"路径。
- **决策序**（behavior_move._handle_path_block）：
  1. 远程特例（弓/杖）：拦路者在射程内 → 边走边射不停车（复用 kite 边打边走的
     衔接；不进 attack 行为即不触发后撤风筝/持瞄，两条链路不打架）；
  2. 侧向有空隙（探测窗 120px【提案/待定】内有净空）→ 局部绕行（复用让路横分量
     几何的敌挡路版，与目标方向点乘恒 0 不减速；侧别优先挡路者反侧，对称僵局按
     实例奇偶拆半）；
  3. 无法简单绕过（两侧被占 / 敌已贴身 ≤70px / 绕行超 3s）→ 请求 AIController
     转入攻击拦路者（**打通态**）。
- **打通态粘性**（ai_controller._breach_target / _breach_tick）：原号令
  `_ordered_behavior/_ordered_params` 不清空不降级；攻击行为经 `forced_target`
  锁定拦路者；击杀或脱离（>320px【提案/待定】）后清态，命令覆盖段自动续行原
  move 号令——恢复的目标点仍是原号令目标。新号令（set_order）显式接管时插叙作废。
- **集体语义**：一个班多单位同时被拦时各自独立判定（涌现出班级接战线），不做
  班级协同决策。

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

> **实现状态**：决策优先级当前**确定性硬编码**（压制避战 > 命令覆盖 > 战斗 > 跟随 > work > idle），见 `ai_controller.gd _make_decision`，计划抽成 `.tres` 数据驱动；单位级强制溃逃链已随裁决【删溃逃、立避战】删除（士气=避战打分输入，避战行为态经 `AIController.is_disengaging()` 查询）；§7.4 第一层概率钩子**已在役**（档案参数化，生效层开关表见 12-游戏AI系统.md §7.3），第二层战场导演情绪标签未接通（`battle_ai_director.gd` 在库待接线）。

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
- `PANICKED` — 恐慌（找掩体优先级最高、大概率触发避战脱离）
- `STEADY` — 稳定（默认）

**卡死看门狗**：`ai_controller._watchdog_tick` O(1)（只记上次采样位置 + 计时，零扫描零分配）——有移动意图（>10px/s）但窗口 2s 内净位移 <12px 判卡死，处置 = 重进 attack（enter 清目标/持瞄，下一拍重选）+ 0.25s 随机方向分离推力；无移动意图自动清零豁免（站桩输出/压制/硬直/待命不误伤）。档案键 `stuck_watchdog_*` 五键（12-游戏AI系统.md §7.3）。

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

命令在两个指挥官之间的延迟 = **消息物理传播的时间**（`传播距离 ÷ 媒介速度`），逐跳中继：

- 同图按两指挥官实体位置的真实距离；跨图按驻地（location）间距离
- 媒介速度查表（BalanceConfig，按科技阶段换代：传令兵跑步 → 骑马传令 → 后续通信科技）
- **层级数本身不产生延迟**——同层远距两节点可以比跨层相邻两节点更慢
- 玩家附身某指挥官亲自下令 → 该环节无传播（玩家的话已在那个人嘴里）
- 信使实体化（真实跑动/可截杀/阵亡丢令）为后续信使任务，接口见 [`组织系统架构.md §4.2`](../组织系统架构.md)

### 8.6 最高指挥单位与军衔体系（斩首规则）

**军衔数据层**（`StickmanEntity.rank`，0/1/2/3 int，任命链写、渲染方消费）：

| rank | 称谓 | 层级语义 |
|------|------|---------|
| 0 | 士兵 | 大头兵，无标记 |
| 1 | 班长 | **战术轮转层**——阵亡免费无缝继任（组织侧 `_run_succession` 现链：班内存活按 personnel 序，cmd 属性平局按插入序稳定排序），无延迟无惩罚，军衔点跟职务走 |
| 2 | 排长 | **指挥链层**——阵亡无法现场补员 = 该排持续指挥链缺口（非一次性扣减，是持续状态；行为影响挂 RL/后续批次） |
| 3 | 指挥官 | 战场最高（连长级兼任）——**斩首规则载体** |

**斩首规则**（结算：`battle_instance._check_victory` 斩首分支，先于全灭判定）：

- 指挥官阵亡 = 该方**立即战败**（reason=`decapitation`，收束原因表见 [02-战斗系统.md §八-A](../../../设计/系统/02-战斗系统.md)）——哪怕还有兵也是败：指挥链崩就是战败，不用打到全灭。
- 登记：`add_unit` 自动扫描 rank>=3（生产战场零接线；单位进战斗前 rank 须已设置），`register_commander` 供后设 rank/测试桩手动补登；同阵营后到覆盖（"战场最高"唯一）。无登记的战斗斩首分支恒跳过（既有战斗零回归）。
- **指挥官行为守卫**（`ai_controller`）：rank>=3 拒推进/撤离类号令（move/retreat/seek_cover；idle 放行）——留守后方，任何来路的号令都拉不走他；避战豁免（C6 概率调制对指挥官恒不触发，`is_disengaging` 恒 false）——被近身就地自卫反击（行为层追击 LEASH 内迎击，敌远不追；低血找掩体保留——就近掩体仍属还击）。
- 双方指挥官同殁 = 平局（复用 `mutual` 口径）。

观察场接线（`battle_arena.gd`）：双方阵列后方各生成 1 名指挥官（rank3、佩剑、不编班不下令）；
生产战场的指挥官生成与 UI 接入挂后续批次。军衔标记（血条军衔点）渲染为独立批次。
### 8.7 排聚合层（现实军衔体系重排，formation 侧实现）

**编制结构**：班 squad（8~12 人小班、硬顶 15，班长 rank 1）→ 排 platoon（2~3 班 + 排长 1 名 rank 2）→ 连/战场（2~4 排 + 连长或指挥官 rank 3，挂载点 = platoon 的 `company_id` 预留字段，指挥官批次接入）。班是组织侧 L1 节点；**排是 FormationSystem 战斗域本地聚合（不入组织树）**——组织侧继任/补位只认班的指挥官，排长阵亡天然无继任，"屏蔽继任"由构造保证。

**排层 API**（`FormationSystem` 实例方法）：`create_platoon(squad_ids, name)` / `assign_platoon_leader(pid, unit)`（排长须为排内班成员，随班行军占编队槽位）/ `get_platoon_leader` / `get_platoon_squads` / `get_platoon_of_squad` / `get_unit_platoon` / `get_platoon_units` / `disband_platoon`（班保留转独立）/ `has_squad_command_chain(squad_id)`；信号 `platoon_created` / `platoon_leader_lost`。

**火力组层**（班内指挥分组，RL v3 编制地基【提案/待定】）：组 = 班内成员子集 + 组寻址 id（`fireteam_N`），**不占军衔不入组织树**（组长 = 组内首员，无标记）——只是号令的粒度，不是行政单位。API（`FormationSystem` 实例方法）：`create_fireteam(squad_id, units, name)` / `get_squad_fireteams(squad_id)` / `get_fireteam_units(ft_id)` / `get_unit_fireteam(unit)` / `get_fireteam_squad(ft_id)` / `is_fireteam(id)` / `get_fireteam_leader(ft_id)` / `disband_fireteam(ft_id)`。号令寻址：`TacticalOrders.issue` 对 ft_id 直令（收令成员 = 组员、战斗职责沿父班、不触发班粒度相位计划——军师规划器仍按班下令），按班下令原语义不变。组不拆散班聚结（一次性归队锚点仍是班长）；组随成员阵亡收缩、空组自动消亡；战斗域本地聚合（同排口径，不进跨图快照，`disband_all_squads` 一并清空）。

**缺口语义**：排长阵亡 = 该排指挥链缺口——该排全部班**失去集火号令**（共享目标决策权归排长，`_decide_squad_targets` 按排查权属：排内班 rep=排长、缺口即 erase 不退化；独立班保留旧口径：班长决策、失效退化首个存活队员）与**排长士气光环**（排长存活 → 排内全员恢复；独立班保留班长光环旧口径），到战斗结束无法补员。班长轮转（组织侧补位回写 `commander_assigned` → 重写 squad.leader + 重算军衔）不受排长缺口影响。一人多职（如排长被补位选中兼任班长）军衔按现任职务取最高（`_recompute_unit_rank`）。

**观察场编成**（`battle_arena.gd` PRESETS，`platoons` = 班下标分组建排）：遭遇战·16 = 1 排（2 班 ×8）；标准战役·48 = 2 排 ×2 班（4 班 ×12）；大军压境·96 = 4 排 ×2 班（8 班 ×12）。兵种结构落到班级（矛先锋/剑中坚/火力压制），出生纵深分排矛前→剑→杖→弓后。每班劈两个火力组（一号/二号，劈法 = 班长外按出生序对半——出生序 = 武器行主序，前半靠前接敌、后半靠后火力支援）。一屏战场几何（创始人：战场范围限定在屏幕一样大）：出生中心 ±700、全部武器行按纵深行距 50 均匀收排（相邻行 Δx≥50 > 分离椭圆横半径 48，任意纵距不违反分离不变式；行内纵距下限 72）、指挥官阵列再后退 120——三档全场跨度最大 ≈ ±1170，观战缩放 0.75（缩放条 100% 档，可见半宽 1280）整场一屏内可见【提案/待定·待实测校准】。

### 8.8 阵列间距椭圆口径与班内聚拢（Boids 式裁剪）

**分离椭圆口径**（单一真相源 `formation_spacing.gd`，经 `FormationAPI` 转发）：旧圆形 `SEPARATION_RADIUS=40.5` 拆双轴——`SEPARATION_RADIUS_X=48`（横向）/ `SEPARATION_RADIUS_Y=72`（纵深，约横向 1.5 倍；billboard 竖长卡纵深视觉重叠是"排列太密集"主因）；`SEPARATION_RADIUS` 保留为兼容别名（=X）。数值【提案/待定·待实测校准】。不变式：碰撞体宽 < X ≤ 横向间距 < Y ≤ 列间距。**椭圆判定的消费方改造**（entity_motion `_apply_separation`/`_apply_static_separation`、battle_sim 分离循环，位置见收线报告清单）由集成批次落，改前消费方经别名自动跟随横向口径（圆 48）。编队列间距 `ROW_GAP_DEFAULT` 56→80（≥ Y+余量，调参表 `var_row_gap` 同步）。

**班内聚拢**（`squad_cohesion.gd`，Boids 三力裁剪的二、三力；分离力归椭圆分离）：聚拢弹簧 = 单位距本班质心超过班散布半径（8 人班 140px、每增 1 人 +6）才回拉，随超出距离线性增强、上限封顶（220）——**死区内零施力，只拉掉队的不吸站好的**；对齐 = 行军速度向班均速收敛（班均速 > 20 才生效，站桩不抖）。门控：接战中（behavior=attack）回拉减半；撤退/避战（retreat/seek_cover）全零。消费出口 `FormationSystem.get_unit_cohesion_steer(unit)`（转向建议，加速度量纲）——**力的施加经消费方转向通道（entity_motion 集成清单见收线报告），不直改位置**。
