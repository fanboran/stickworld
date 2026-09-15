# combat：战场组织与战斗 AI

> 战斗的组织层：多战场调度与战斗实例、编队/号令/指挥链、阵营 AI 与任务槽、伤害管线与批模拟、战斗 UI。单位级行为状态机在 [modules/units/](../units/README.md)，本模块不碰单位级决策。
> - `scripts/battle/`：战斗实例/导演/阵营 AI/任务槽/效用打分/伤害管线/批模拟/掩体
> - `scripts/command/`：编队/号令/指挥链/框选/小队相位计划
> - `scripts/target_finder.gd`：公共目标选择核心（本模块对外公共类，units 行为层复用）
> - `ui/`：战斗面板/编制窗口/L1 班组卡/TeamAi HUD
>
> 对外契约见 [api.gd](api.gd)（CombatApi）：`start_battle` / `issue_order` / 编队跨图快照三族方法，
> BattleDirector / TacticalOrders / FormationSystem 引用由装配层注入（setup / set_tactical_orders /
> setup_formation_system）；FormationSystem 为内部类，外部经实例注入 + duck 协议使用。
>
> 系统级设计规范：[docs/技术/架构/场景与战斗架构.md](file:///f:/VSCode/game-2/docs/技术/架构/场景与战斗架构.md) §8、
> [docs/设计/系统/12-游戏AI系统.md](file:///f:/VSCode/game-2/docs/设计/系统/12-游戏AI系统.md)。

---

## 目录结构

```
modules/combat/
├── api.gd                                    # 对外 API（CombatApi：start_battle/issue_order/export_squads 等，委托注入的宿主节点）
├── scripts/
│   ├── target_finder.gd                      # TargetFinder：目标选择核心（opts 链式过滤：prefer_low_hp/prefer_large/fixate_on/防集火/AOE 扇形）
│   ├── battle/
│   │   ├── battle_director.gd                # BattleDirector：多战场调度（挂 GameRoot.BattleDirector；TeamAi 生产启用开关读 personality）
│   │   ├── battle_instance.gd                # BattleInstance：单场战斗宿主（状态流转/士气事件/防集火/批模拟装配/TeamAi 注册制）
│   │   ├── battle_sim.gd                     # BattleSim：数据化批模拟内核（SoA 扁平数组批量推进移动/分离/冷却/命中时序）
│   │   ├── battle_ai_director.gd             # 战场导演：2~5s 给单位打情绪标签（影响 WeaponMount 命中率/冷却）
│   │   ├── team_ai.gd                        # TeamAi：阵营 AI 姿态机（节拍分帧/姿态决策/任务槽驱动/号令下发/效用打分接线）
│   │   ├── team_ai_profiles.gd               # TeamAiProfiles：阵营 AI 参数档案（DEFAULTS + personality 档案合并）
│   │   ├── task_board.gd                     # TaskBoard：攻/防任务槽（创建杀槽/槽↔小队匹配/四因子目标评分留痕）
│   │   ├── utility_scorer.gd                 # UtilityScorer：效用打分选择器（filter/demand/target 三件套 + softmax 轮盘 + 冷却）
│   │   ├── damage_pipeline.gd                # DamagePipeline：伤害单入口（修饰链/入血/反伤/表现链，禁绕过直调 take_damage）
│   │   └── cover_system.gd                   # CoverSystem：掩体查询（扫描 group "cover_marker"）
│   └── command/
│       ├── formation_system.gd               # FormationSystem：编队（小队/预设/职责/槽位列阵/跟队/权威值/相位计划宿主段/跨图快照）
│       ├── tactical_orders.gd                # TacticalOrders：号令下达入口（issue 小队直令 / issue_to_org 组织逐层）
│       ├── command_chain.gd                  # CommandChain：号令送达执行器 + 逐跳接力（传播延迟 = 距离 ÷ 媒介速度）
│       ├── selection_system.gd               # SelectionSystem：BATTLE 模式框选/点选（InputDispatcher handler）
│       └── squad_phase_plan.gd               # SquadPhasePlan：小队相位计划（角色分派 + 交替掩护跃进相位机，纯逻辑无自转）
└── ui/
    ├── battle_panel.gd                       # 战斗面板（框选信息/编制入口/号令按钮）
    ├── formation_panel.gd                    # 编制管理窗口（创建编队/职责勾选/任命排长/解散，村庄战场通用）
    ├── squad_card.tscn / squad_card.gd       # L1 班组卡（状态徽标/号令栏/班长权威值对比/成员行，挂 ContextPanel 槽）
    ├── squad_member_row.tscn / squad_member_row.gd  # 班组卡成员行（角色角标/士气微型条/单兵状态，纯呈现件）
    └── team_ai_hud.tscn / team_ai_hud.gd     # TeamAi 状态 HUD（姿态徽标/attack%/任务槽占用，F3 drawer 开关）
```

---

## 依赖

- `modules/units/`：唯一路径 preload 是 battle_instance.gd → modules/units/scripts/rig/crowd_renderer.gd（批模拟单位的渲染代理）。其余一律弱类型：`StickmanEntity.set_battle_sim` / `set_formation_system` 注入后 duck 调用；`ui/` 全程 has_method 探测，查询不可用即跳过该行或整卡收起。
- `modules/organization/`：经 OrganizationApi 弱类型引用（编队落 L1 组织节点、issue_to_org 的 hop 计划与传输秒数、指挥官在册查询），不 preload 内部文件。
- 装配（modules/world 的 SystemSetup）：给 GameRoot.BattleDirector 挂脚本、实例化 CombatApi、装配 TacticalOrders / CommandChain / FormationSystem / SelectionSystem / UnitLodDirector 与战斗 UI——本模块节点不自行进树。
- 平衡数据（BalanceConfig，手写档案非 Excel 导出）：`ai.personality`（单一参数档案 global 行：节拍/开局门禁/攻击百分比/任务槽评分权重/效用打分与 softmax/team_ai_enabled）、`ai.squad_phase_plan`、`ai.formation_authority`、`ai.org_default_behavior`、`ai.behavior_profiles`（units 档案的行覆盖层）。

---

## 开发注意事项

### 战场层级与数据流

```
GameRoot.BattleDirector（多战场调度；team_ai_enabled 开时对双方启用 TeamAi）
└── BattleInstance（挂 MapInstance.BattleAnchor；PREPARING→ENGAGED→攻/守胜/平）
    ├── BattleSim（参战 AI 单位批模拟：移动积分/群体分离/冷却/命中时序；实体降级渲染代理）
    ├── BattleAIDirector（周期情绪标签 → WeaponMount 命中率/冷却）
    ├── TeamAi ×2（阵营姿态机，enable_team_ai 注册制，未注册零开销）
    │   └── TaskBoard（攻/防任务槽）＋ UtilityScorer（default_behavior 打分）
    ├── DamagePipeline（一切伤害单入口；HealthComponent 仍是血量权威）
    └── CoverSystem（掩体查询；战场地图未放 CoverMarker 时恒为空）
```

号令链两条：`issue`（小队直令，玩家微操与 TeamAi 现场指挥，零延迟）→ CommandChain.deliver → 单位 AIController.set_order；`issue_to_org`（组织层级）→ hop 计划 → deliver_via_orgs 逐跳物理传播，L1 送达即执行，伤亡空缺的中间层命令停驻丢弃。TeamAi 下发号令统一 source_tier=1；玩家手动号令 tier=0 且带保护期（manual_order_guard，保护期内姿态号令避让）。battle_ended 的 victory 语义 = 玩家阵营胜（set_player_faction 基准），非攻方胜。

### 阵营 AI（TeamAi）

- 节拍分帧：beat_interval（0.5s，下限 MIN_BEAT_INTERVAL）基础节拍上 DECIDE / BUILD 双相位轮转，决策不逐帧思考；暂停/非 ENGAGED 不累积。
- 姿态机：GARRISON/DEFEND/ATTACK 双阈值滞回（attack_enter/exit、defend_enter/exit）+ 统一切换冷却；开局攻击门禁 = seconds_before_attack ± start_attack_variance 掷骰（默认固定种子 DEFAULT_RANDOM_SEED，单测可锁、扫参可复现）。第四姿态 ROUT 为撤仗终态：战役三阈值（伤亡率/战损比/相持超时）默认全负不评估，据点战经 overrides 注入，任一满足即全军 RETREAT 撤离离场（单位 departed 计非存活）。
- 决策内核双轨：slot_kernel_enabled=true 走任务槽（有攻击槽→ATTACK，槽清空→DEFEND）；false 或任务板缺失退化为 should_attack/should_defend 比例条件。
- 任务槽（TaskBoard）：TeamAi 只创建/杀槽（期望进攻槽数 = attack% × 原子单元数），槽↔小队匹配归执行侧 match_groups（组织化编制一组/散兵一组）；槽带集结点与集结/目标超时；目标评分四因子 threat / avoid_clumps / distance / inertia（防振荡），权重真值在档案。
- 攻击百分比四规则（优先级高→低）：胜利目标危急（vp_rule_enabled 缺省关）→ 基地威胁封顶 → 基调曲线（baseline + 每分钟递增，封顶 max）→ 军力优势递增；结果缓存在 `get_attack_percentage`，HUD 轮询不重算。
- 效用打分（default_behavior v2）：组织 default_behavior 字段的候选集经 UtilityScorer 打分——filter 资格谓词（未知谓词 fail-closed）+ demand ±demand_increment 打分 + softmax 轮盘选优（weight/weight_rules 静态权重可委托）+ 冷却；选择结果映射为号令下发。配置生产端在 config/ai/org_default_behavior.tres（writer_enabled 总闸控制写入组织，消费门 default_behavior_v2_enabled 是独立闸）。
- 参数合并序：代码默认（team_ai_profiles.gd `DEFAULTS`）< personality.tres global 行（load_personality_overlay）< enable_team_ai 显式 overrides；DEFAULTS 之外的新键（如 default_behavior_v2_enabled / softmax_* 族）需在 team_ai.gd `setup` 的补挂循环显式加键。

### 编队（FormationSystem）

- 小队 = L1 MILITARY 组织节点；本地维护 unit↔squad 双向映射；编制预设来自 config/formations/formation_presets.tres（内置战斗班兜底）。职责 WorkType 五类（COMBAT/BUILD/HAUL/TRANSPORT/FORAGE），HAUL 是全员基础能力 `is_work_allowed` 恒放行；排长任命/补位经 EventBus.commander_assigned 回写。
- 结构列阵：每列 UNITS_PER_COLUMN=3、列距 ROW_GAP，槽位随成员增减自动重算；`get_squad_dest mode="formation"` 取槽位落点，距落点过远转奔跑追赶，落定不重发号令；小队可锚定跟随另一小队（前队质心 − 行进方向 × gap，死区防抖，前队全灭自动解除）。
- 队伍级共享目标：每 0.5s 为每个战斗小队选共享攻击目标（经 TargetFinder），队员在攻击行为里优先集火。
- 权威值择班：`get_squad_authority` = 班长在场 1.0 + 组织指挥官在册 0.5 + 班长被玩家附身 0.2；`should_switch_squad` 滞回 authority_margin=0.07。自主跳槽（authority_switch_enabled）按宿主节拍周期评估：邻近班权威对比 + 玩家班吸引/黏性加成 + 单位冷却与错峰相位 + 班长放人阈值 + 单拍迁出上限；迁移复用既有 add_unit（组织同步/角色/槽位一次做全）。
- 小队相位计划（phase_plan_enabled）：推进类号令（ADVANCE_ALL/SPRINT）激活、其余号令撤销；成员分 CORE/SCOUT/左右翼四角色（编队槽位列序 × 素质代理双维），CORE_LEAP→CORE_WAIT→FLANK_LEAP→FLANK_WAIT 交替掩护跃进直至终点。计划逻辑全在 squad_phase_plan.gd（纯逻辑无自转），本系统只做参数装载/号令触发/节拍驱动/查询出口；跟随玩家或锚定跟队的小队不激活。
- 跨图携带：export_squads / disband_all_squads / restore_squads（CombatApi 透传，换图前导出、新图按快照重建）。

### GK 机制开关族

机制统一走「档案开关 + 代码默认兜底 + 单元套件覆盖」；开关真值与参数都在 BalanceConfig 手写档案（F9 热重载）：

| 机制 | 开关/参数（档案路径） | 消费点 | 单元套件 |
|---|---|---|---|
| TeamAi 总开关 | team_ai_enabled（ai.personality.global，缺键默认开） | battle_director.gd `_team_ai_enabled` | — |
| 任务槽内核 | slot_kernel_enabled（ai.personality） | team_ai.gd `_task_board_enabled` → task_board.gd | test_task_board.gd |
| 效用打分 | default_behavior_v2_enabled / demand_increment / demand_variance / softmax_*（ai.personality）；写入端 ai.org_default_behavior 的 writer_enabled | team_ai.gd → utility_scorer.gd | test_utility_scorer.gd / test_org_default_behavior.gd |
| 点射节奏 | burst_shots / burst_wait / night_hesitate_mult（ai.behavior_profiles baseline 行） | units behavior_attack.gd（连射-停顿节奏）+ units weapon_mount.gd（连射散布热度） | test_ai_param_panel.gd |
| 压制=定时锁死 | suppression_enabled 键族（ai.behavior_profiles baseline 行） | units status_effects.gd（触发+士气流失）/ ai_controller.gd（决策禁令）/ arrow_projectile.gd（近失）；squad_phase_plan.gd 消费其查询 | test_suppression.gd |
| 撤退调制 | retreat_mod_enabled 键族（ai.behavior_profiles）+ retreat_chance（ai.personality.global） | units ai_controller.gd（中间带掷骰）+ units behavior_retreat.gd（双档） | test_ai_retreat_modulation.gd |
| 小队相位计划 | phase_plan_enabled（ai.squad_phase_plan.global，生效默认开） | formation_system.gd 宿主段 → squad_phase_plan.gd | test_squad_phase_plan.gd |
| 权威值跳槽 | authority_switch_enabled 键族（ai.formation_authority.global，生效默认开） | formation_system.gd 权威值择班段 + 自主跳槽段 | test_authority_switch.gd |
| 出生错峰/决策时钟 | spawn_jitter_enabled / probe_fail_cooldown_enabled（ai.behavior_profiles） | units ai_controller.gd 决策时钟族（读档按 ai_timing 字段回填） | test_ai_spawn_jitter.gd / test_ai_timing_save.gd |

### 扩展指引：加一个 TeamAi 机制开关

参照既有 GK 开关的完整链，四步：

1. **参数默认键**：modules/combat/scripts/battle/team_ai_profiles.gd 的 `DEFAULTS` 加键（BalanceConfig 缺载兜底值）。注意：新键若不进 `DEFAULTS` 键集（A4/W1 型），须在 modules/combat/scripts/battle/team_ai.gd `setup` 的补挂循环（default_behavior_v2_enabled / softmax_* 同款 for 循环）显式加键，否则 personality 档案的值进不了 `_p`。
2. **档案行**：config/ai/personality.tres 的 global 行加同名键（BalanceConfig 类型路径 ai.personality，F9 热重载生效）。
3. **消费点**：modules/combat/scripts/battle/team_ai.gd（`_run_beat` / `_update_task_board` / 号令下发路径等）按 `_p["<键>"]` 门控。开销敏感的机制必须在开关关闭时零累积零查询——缺省关闭 = 零回归基线是既有惯例；观测面（状态快照查询）随机制一并提供，供调试 HUD 与测试断言。
4. **测试**：tests/unit/ 新建 test_<机制>.gd 并注册进 tests/batch_runner.gd 的 `UNIT_SCRIPTS` 清单——清单有自检，盘上有 .gd 但未注册会判失败。纯 battle_director 侧的消费开关（如 team_ai_enabled）无 unit 套件属正常。

### 扩展指引：加一个兵种行为键

个体层档案在 units 侧，三层合并 = 代码基线（modules/units/scripts/ai/behavior_profiles.gd `BASELINE`）← 代码兵种覆盖（同文件 `CLASS_PROFILES`，只写差异项）← config/ai/behavior_profiles.tres 的 baseline 行与兵种行（同 id 后行覆盖前行）：

1. `BASELINE` 加键，默认值取关闭/零（零回归闸门）。
2. 消费点按 `_profile.get("<键>", 默认)` 读取，位置按机制归属选 modules/units 的 ai_controller.gd / behavior_*.gd / weapon_mount.gd / visual_controller.gd。
3. 调参先改 config/ai/behavior_profiles.tres（热重载），兵种行只写差异项。
4. 单元套件按机制归口（test_ai_param_panel.gd / test_combat_fidelity.gd 等，注册于 tests/batch_runner.gd）。

阵营层的兵种维度键是 TeamAiProfiles 的 `unit_weights`（军事力量权重，PICKAXE=0 非军事）与 `type_priority`（比较器序）：加兵种类别要动 team_ai_profiles.gd 的类别常量、`DEFAULTS.unit_weights` / `type_priority`，并保持与 units 侧 WeaponMount.WeaponType 枚举序对齐（GIANT 为占位类别）。

### 战斗 UI 纪律

ui/ 全部 duck 探测（has_method）取数，查询不可用即跳过该行或整卡收起，不倒逼战斗侧改结构；team_ai_hud 走 EventBus.team_ai_stance_changed 信号 + 低频轮询兜底（`get_attack_percentage` 为缓存查询，不重跑四规则）；场景是布局唯一真相源（骨架在 .tscn，脚本不 new 控件当根）。
