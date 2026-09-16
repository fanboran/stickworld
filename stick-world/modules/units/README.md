# units：火柴人实体系统

> 火柴人完整单兵栈：矢量骨骼渲染 + 物理实体 + 行为 AI。
> - `scripts/rig/`：Skeleton2D 骨架、矢量肢体/批渲染/小兵代理、动画状态机、LOD 节流
> - `scripts/stickman_entity.gd` + `scripts/entity/`：CharacterBody2D 外壳与子组件（生命/武器/交互/血条/状态效果）
> - `scripts/ai/`：行为状态机 + 兵种行为档案
> - `scenes/` `animations/`：实体场景与动画资源
>
> 对外契约见 [api.gd](api.gd)（UnitsAPI）：外部实例化实体一律用 `UnitsAPI.STICKMAN_ENTITY_SCENE`，
> 其余经全局 class_name（StickmanEntity / StickmanRig / HealthComponent…）的公共方法交互。
> 常用出口：StickmanRig 的 `play()` / `animation_finished` / `animation_event` 信号，
> StickmanEntity 的 `set_possessed` / `get_facing` / `ai_move` / `set_ground_constraints` /
> `set_formation_system` / `set_battle_sim`。模块自身不向 EventBus 发射信号。
>
> 系统级设计规范：[docs/技术/架构/场景与战斗架构.md](file:///f:/VSCode/game-2/docs/技术/架构/场景与战斗架构.md) §7、
> [docs/技术/架构/场景与战斗/战斗与AI.md](file:///f:/VSCode/game-2/docs/技术/架构/场景与战斗/战斗与AI.md)。

---

## 目录结构

```
modules/units/
├── api.gd                                # 对外 API（UnitsAPI：实体场景常量 + 契约说明）
├── animations/                           # Animation 资源（55 个 .tres：idle/walk/run/attack*/dead*/hit*/block*/build/heal…；bake_anims 产物）
├── assets/textures/weapons/              # 武器贴图（剑/矛/弓/盾/镐/法杖/箭）
├── scenes/
│   ├── stickman_entity.tscn              # 实体场景（RigHost + Collider + AIController + HealthComponent + Hitbox + WeaponMount + Range；运行时再装配 Visual/Interaction/血条）
│   ├── stickman_test.tscn                # 渲染壳（rig + 调试控制器；HD-2D 角色通道复用取 rig）
│   └── components/                       # 武器/盾/箭矢场景（GripPoint 对齐握把）
├── shaders/
│   ├── stickman_outline.gdshader         # 邻接融合描边 Outline Pass（解码 ID + 查邻接表定融合/分隔）
│   └── stickman_outline_id.gdshader      # ID Pass（part_id 编码进 alpha）
└── scripts/
    ├── stickman_entity.gd                # StickmanEntity：物理外壳（附身输入/AI 移动/地面约束/群体分离/受击反馈/尸体消隐/接触阴影/平衡数据装载）
    ├── rig/                              # 渲染骨架管线
    │   ├── stickman_skeleton.gd          # 骨骼数据（23 骨，含 weapon_hand/shield_hand 武器骨）+ 矢量肢体构建 + 全局两遍渲染
    │   ├── stickman_rig.gd               # StickmanRig 主控（动画树推进/事件派发/LOD 节流/低帧分桶/小兵代理切换/描边缩放补偿）
    │   ├── stickman_anims.gd             # 动画注册表（状态机装配/武器→动画映射表/死亡受击变体池/事件元数据）
    │   ├── stickman_batch_rig.gd         # 批渲染层：每单位 4 个 MultiMesh 桶替代约 30 个矢量部件（开关 STICK_BATCH_RIG）
    │   ├── crowd_renderer.gd             # 小兵渲染代理：全战场共享 4 桶 MMI + 代码插值动画（开关 STICK_CROWD）
    │   ├── stickman_outline.gd           # 邻接融合描边装配（供 HD-2D 角色通道的 CanvasGroup 用）
    │   ├── procedural_overlay.gd         # 程序化叠加层（呼吸/移动惯性/挥击回弹/受击抖动）
    │   ├── crowd_bar_wobble.gdshader     # 小兵代理血条桶着色器
    │   ├── crowd_weapon_atlas.gdshader   # 小兵代理武器图集桶着色器
    │   └── stickman_test.gd              # 渲染壳调试控制器（实体场景实例化时禁用其脚本）
    ├── entity/
    │   ├── visual_controller.gd          # 动画播放组件（搬运映射/动作锁定/待机变体/受击插播/持盾姿态/头顶进度条）
    │   ├── interaction_controller.gd     # 按 F 交互（工地交付与建造/仓库取放/兵营招兵/资源采集）+ 交互提示弹窗
    │   ├── health_component.gd           # HP/士气组件（died/damaged/healed/morale_changed 信号）
    │   ├── health_bar_indicator.gd       # 头顶阵营点 + 手绘血条（满血=点、掉血=条，自绘无资源依赖）
    │   ├── action_progress_indicator.gd  # 头顶动作进度条（搬运/建造，行为脚本经 set_action_progress 更新）
    │   ├── weapon_mount.gd               # 武器挂载/攻击执行/命中帧事件/格挡/放箭/召唤与法术
    │   ├── block_resolver.gd             # 盾牌格挡纯判定（正面扇区 + 概率掷骰，无状态）
    │   ├── hitstop_controller.gd         # 命中顿帧（仅附身命中触发，全局最小间隔节流）
    │   ├── hitbox.gd                     # 受击判定 Area2D + 碰撞层 bit 常量
    │   ├── status_effects.gd             # 状态效果（BURN/POISON/SLOW/STUN/HEAL/SUPPRESSED）
    │   ├── incoming_threat_ledger.gd     # 在飞箭矢账本（伤害估计 + 威胁时刻）
    │   └── unit_lod_director.gd          # 战斗级 LOD 调度（T0/T1/T2 三档 + 滞回 + 恐慌降刻，SystemSetup 装配）
    ├── ai/
    │   ├── ai_controller.gd              # AI 决策大脑（行为调度/决策时钟/号令覆盖/狂暴被围/撤退调制/出生错峰）
    │   ├── behavior_state_machine.gd     # 行为状态机
    │   ├── behavior_base.gd              # 行为基类
    │   ├── behavior_attack.gd            # 攻击（选敌/接近/命中帧出手/瞄准节奏/点射/包抄/保距/走位对齐）
    │   ├── behavior_move.gd 等 10 个     # move/idle/follow/retreat/seek_cover/heal/harvest/haul/wander/work
    │   └── behavior_profiles.gd          # 兵种行为档案（代码基线 + 代码兵种覆盖 + BalanceConfig 行覆盖，三层合并）
    └── weapons/
        ├── stickman_weapon.gd            # 武器挂到手骨（双持：右手 weapon_hand / 左手 shield_hand）
        └── arrow_projectile.gd           # 箭矢（抛物线弹道/爆头/插身/插地/近失判定/飞行时间伤害衰减）
```

---

## 依赖

- `modules/combat/`（唯一跨模块代码出口）：TargetFinder（combat 对外公共目标选择类）——behavior_attack / behavior_heal / weapon_mount 三处经行内 `audit-exempt` 标记路径 preload。除此之外不 preload combat 任何内部文件：编队职责走 duck 协议（FormationSystem 实例由装配层经 `set_formation_system` 注入，`is_work_allowed`/`is_unit_squad_following` 未注入时放行），阵营姿态常量与工作类型常量在 ai_controller.gd 持本地副本。
- 平衡数据（BalanceConfig autoload，缺载回退代码默认）：`units.stickmen`（兵种 base_hp / base_attack，按 `stickman_def_id` 取行）、`balance.variables`（var_walk_speed / var_run_speed / var_base_scale）、`ai.behavior_profiles`（兵种档案行覆盖）、`ai.personality`（retreat_chance 撤退掷骰概率）。
- 离线管线 `tools/baking/`：bake_anims.tscn 烘焙 animations/*.tres；spine_import.gd 导出动画事件元数据（Hit/Sound/Drawn/Mine）；extract_weapons.gd 裁剪武器贴图。

### 与 combat 模块的边界

- units → combat：只有 TargetFinder 一条路径（见上）。个体 AI 不感知 TeamAi/TaskBoard；撤退掷骰概率经 `BehaviorProfiles.get_personality_retreat_chance()` 读 BalanceConfig，不直连 combat 代码。
- combat → units：BattleInstance 经 `scripts/rig/crowd_renderer.gd` 挂小兵渲染代理、经 `set_battle_sim()` 把参战实体降级为渲染/受击代理；FormationSystem/TeamAi 不被 units 引用，靠装配层注入 + duck 协议闭环。
- 依赖现状（audit_deps 口径）：combat ↔ units 存在二元环——units→combat 的三处 TargetFinder audit-exempt preload，与 combat→units 的 crowd_renderer preload；收敛工作项见 docs/项目/待办事项.md AR 系列。

---

## 开发注意事项

### 渲染三轨与开关

同一骨架有三条渲染路径，可独立开关、构建失败自动回退：

| 路径 | 载体 | 开关 |
|---|---|---|
| 骨骼富管线 | 每单位约 30 个矢量部件（描边/填充两层的 Line2D/Polygon2D） | 默认路径；编辑器内恒用；批渲染构建失败时回退 |
| 批渲染 | 每单位 4 个 MultiMeshInstance2D 桶（描边矩/圆 + 填充矩/圆） | ProjectSettings `render/batch_rig`（默认开）；env `STICK_BATCH_RIG=0/1` 覆盖 |
| 小兵渲染代理 | 全战场共享 4 个 MMI 桶 + 代码插值动画，rig 隐藏退居播报 | ProjectSettings `render/crowd_renderer`（默认开）；env `STICK_CROWD=0/1` 覆盖；进出经 `StickmanRig.set_crowd_hook` |

参战单位被 combat 的 BattleSim 批模拟接管时即走小兵代理路径。身体色恒为 `Skeleton.DEFAULT_BODY`：阵营识别走血条颜色、职业识别走武器变体，不做身体染色。

### 邻接融合描边（HD-2D 角色通道专用）

- 2D 战场：矢量肢体全局两遍渲染——描边层 z=-1 压底、填充层 z=0 置顶，重叠处填充无缝融合，只出整体剪影描边；相机拉远时 `StickmanRig._update_outline_zoom` 按画布缩放补偿描边宽度，屏幕上恒定约 1px（`OUTLINE_SCREEN_PX=1.0`）。
- HD-2D 角色通道（每角色独立 SubViewport 渲染）：`StickmanOutline.setup` 给 CanvasGroup 启用 ID Buffer + 邻接表描边（shaders/stickman_outline*.gdshader）——零件 part_id 编进 alpha，Outline Pass 查邻接表判定「相邻融合轮廓 / 不相邻画分隔线」。现行口径为全融合：全部零件同一 ID，只画剪影外轮廓；骨骼名 6 分组常量与肩甲补丁槽位（ID 15）保留在表未启用。

### LOD 与低帧分桶

- `UnitLodDirector`（10Hz 重算档位）：T0 近景按存活数密度自适应 60/30/20/15Hz，T1 中景 15Hz，T2 远景 5Hz + rig/血条隐藏；换档带 15% 滞回；fps 持续走低时恐慌降物理刻（15Hz/10Hz，恢复阈 25fps）。hz 永不向下钳制——低帧下动画本就随帧率自然降频，再钳会「定格-跳帧」。
- rig 侧：LOD 驱动模式按 hz 手动 advance；fps<6 进低帧分桶错峰推进（<3 → 4 桶，否则 2 桶）；动画结束/事件检测隔帧轮询（30Hz 采样不漏「越过时间点」语义的事件）。
- 运行时 IK 修改器栈默认禁用（骨骼姿态由动画 track 持久驱动）；env `STICK_RIG_IK=1` 恢复开栈行为。

### 速度体系

实际移速 = 基速 × 多级乘子，逐级独立可调：

- 基速：`WALK_SPEED=160` / `RUN_SPEED=320` px/s（run=步行×2 的常识比例；balance.variables 的 var_walk_speed / var_run_speed / var_base_scale 可覆盖；附身时 Alt 切散步模式锁 walk）。
- 乘子链（`_apply_movement`）：地形倍率（地图查询）× `move_speed_mult`（行为档案 move_mult 写入，兵种机动性差异）× 状态减速（SLOW ×0.5）× 举盾倍率 × `armor_speed_factor`（背包装备三件 speed_penalty 乘积）。
- 动画联动：walk 动画播放速率随速度缩放（速度 100px/s 对应 1.0×，整体再 ×1.4，下限 0.6×）；run 动画速率随跑速等比缩放（跑速 208px/s 对应 1.0×，同 ×1.4），低于 `IDLE_THRESHOLD=5` px/s 回 idle。

### 朝向翻转

`_facing`（1=右 / -1=左）统一驱动三件事：`rig.scale.x` 镜像、Collider/Range/Hitbox 的 X 偏移镜像（均在 `_apply_scale`）、格挡正面扇区判定（BlockResolver.is_frontal）。移动换向、`face_towards()` 会改写它。新增左右不对称的节点或判定必须接入 `_apply_scale`，不要各自另写翻转。

### 扩展指引：加一个新姿态动画

1. `animations/<名>.tres`：动画资源（骨骼 rotation 轨道；tools/baking/bake_anims.tscn 烘焙；一次性动画 LOOP_NONE）。
2. `scripts/rig/stickman_anims.gd`：加常量 → `setup_player` 里 `_load_anim` 入库 → `setup_tree` 建 state 与过渡。一次性动画必须 AT_START 切入（sync=false + reset=true），否则会从旧动画进度映射进来、越过内嵌事件。
3. 消费侧三选一：实体组件（visual_controller.gd 播放与播完回切）、行为脚本（如 play_attack）、或档案池键（behavior_profiles 的 attack_pool / stand_pool / block_* 系，按武器类型随机抽取）。
4. 命中/音效时机写成动画元数据事件（Hit/Sound/…），消费方经 `StickmanRig.animation_event` 信号或 `get_anim_event_time` 读真值，禁止按动画进度比例拍脑袋折算。
5. 单元套件：tests/unit/test_stickman_anims.gd（注册于 tests/batch_runner.gd 的 UNIT_SCRIPTS 清单）。

### 扩展指引：加一件武器 / 装备部位

- 主手武器：`scenes/components/weapon_<x>.tscn`（贴图放 assets/textures/weapons/，场景带 GripPoint）→ `weapon_mount.gd` 的 `WeaponType` 枚举 + `WEAPON_SCENE_PATHS` + `WEAPON_RANGE` → `stickman_anims.gd` 的 `WEAPON_ATTACK_ANIM` / `WEAPON_IDLE_ANIM` 表加同序键 → 兵种档案 `behavior_profiles.gd` 的 `CLASS_PROFILES` 写个性参数（或 config/ai/behavior_profiles.tres 行覆盖）。武器→动画映射表是播放侧与命中帧结算侧共用的单一真相源，漏改会出现「播 A 武器动画、按 B 武器命中帧结算」的错配。
- 盾/副手：weapon_shield.tscn 挂 shield_hand 骨；格挡数值（BLOCK_CHANCE / BLOCK_DAMAGE_FACTOR / 正面扇区）在 weapon_mount.gd，判定逻辑在 block_resolver.gd。
- 护甲：实体只存 `armor_speed_factor` / `armor_damage_reduction` 两个值（背包装备系统写入，减伤加和封顶 0.6），消费在移速乘子链与 `get_armor_factor()`；装备栏逻辑归 inventory 模块，实体侧不开口子。

### 单元测试

相关套件：test_stickman_anims / test_health_component / test_strike_frame / test_combat_fidelity / test_incoming_threat_ledger / test_behavior_state_machine / test_behavior_harvest / test_ai_param_panel / test_ai_retreat_modulation / test_suppression / test_ai_spawn_jitter / test_ai_timing_save（均在 tests/unit/，运行方式见 [docs/技术/教程/测试矩阵.md](file:///f:/VSCode/game-2/docs/技术/教程/测试矩阵.md)）。
