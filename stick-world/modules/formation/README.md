# formation：战斗阵列（编队与编制）

> 战斗中的"阵列"整条业务：小队/编队槽位、槽位几何、编队动态跟队、相位跃进计划、编制旁支（快照/权威值/上报）与编制 UI。
> - `scripts/formation_system.gd`：编队系统总成（小队 = L1 组织节点、槽位表、跟队、共享目标、权威值择班、相位计划宿主段、跨图快照）
> - `scripts/formation_spacing.gd`：间距/物理分离**单一真相源**（体宽 < 分离半径 < 横向间距 ≤ 列间距；死区与到位容差不变式见文件头）
> - `scripts/formation_geometry.gd`：槽位几何 static 库（面向轴/槽位落点/槽位重算 + 贪心换位）
> - `scripts/squad_follow_director.gd`：编队动态跟队（后队落点 = 前队质心 − 行进方向 × gap，锚定链防环）
> - `scripts/squad_phase_plan.gd`：小队相位计划（CORE/SCOUT/左右翼四角色，交替掩护跃进，纯逻辑无自转）
> - `scripts/squad_snapshot.gd` / `squad_authority_market.gd` / `squad_report_hooks.gd`：跨图快照恢复 / 权威值择班市场 / 信息上报与征用互斥
> - `ui/`：编制管理窗口（formation_panel）、L1 班组卡（squad_card + 成员行 squad_member_row）
>
> 对外契约见 [api.gd](api.gd)（FormationAPI）：间距/分离半径常量（units 实体链与 combat 批模拟同源读取）+
> 装配注入的运行期 FormationSystem 实例（duck 调用）。**外部模块禁止 preload 模块内部脚本路径**。
>
> 边界：号令的语义与目标选择（TacticalOrders / TargetFinder）属 [modules/tactics/](../tactics/README.md)，
> 号令的下发链（CommandChain）属 [modules/combat/](../combat/README.md)——本模块只回答
> "人站在哪、阵列怎么排、何时算到位"，号令经 `get_squad_dest(…, "formation")` 取落点。
> 共享目标选型与推进类号令枚举直取 `../tactics/api.gd` 契约出口（Orders / Finder 常量）。
>
> 系统级设计规范：[docs/技术/架构/场景与战斗/场景与战斗架构.md](file:///f:/VSCode/game-2/docs/技术/架构/场景与战斗/场景与战斗架构.md) §8.2/§8.3。

---

## 目录结构

```
modules/formation/
├── api.gd                                # 对外契约（FormationAPI：间距常量转发 + 运行期实例注入说明）
├── scripts/
│   ├── formation_system.gd               # FormationSystem：编队总成（小队/预设/职责/槽位列阵/跟队/共享目标/权威值/相位计划宿主段/跨图快照）
│   ├── formation_spacing.gd              # FormationSpacing：间距/分离半径/死区/到位容差单一真相源（不变式注释）
│   ├── formation_geometry.gd             # 槽位几何：member_facing / slot_world / assign_formation_slots（列收缩 + 贪心换位）
│   ├── squad_follow_director.gd          # 编队动态跟队：锚定落点维持/号令下发/防环
│   ├── squad_phase_plan.gd               # SquadPhasePlan：相位跃进计划（角色分派 + 相位机，纯逻辑）
│   ├── squad_snapshot.gd                 # 跨图快照/恢复 + BalanceConfig 参数装载（load_overrides）
│   ├── squad_authority_market.gd         # 权威值择班市场（周期评估/错峰相位/转投守卫）
│   └── squad_report_hooks.gd             # 信息上报挂点（contact/casualty）+ 编队征用互斥
└── ui/
    ├── formation_panel.gd                # 编制管理窗口（创建编队/职责勾选/任命排长/解散，村庄战场通用）
    ├── squad_card.tscn / squad_card.gd   # L1 班组卡（状态徽标/号令栏/班长权威值对比/成员行，挂 ContextPanel 槽）
    └── squad_member_row.tscn / squad_member_row.gd  # 班组卡成员行（角色角标/士气微型条/单兵状态，纯呈现件）
```

---

## 机制要点

- **小队** = L1 MILITARY 组织节点；本地维护 unit↔squad 双向映射；编制预设来自 config/formations/formation_presets.tres（内置战斗班兜底）。职责 WorkType 五类（COMBAT/BUILD/HAUL/TRANSPORT/FORAGE），HAUL 是全员基础能力 `is_work_allowed` 恒放行；排长任命/补位经 EventBus.commander_assigned 回写。
- **结构列阵**：每列 UNITS_PER_COLUMN、列距 ROW_GAP、横向间距 SPREAD_SPACING（默认值全在 formation_spacing.gd，横向/列距可经 `balance.variables` 的 `var_spread_spacing` / `var_row_gap` 覆盖）；槽位随成员增减自动重算（列收缩不留空列 + 贪心换位缩短行军穿插）；`get_squad_dest mode="formation"` 取槽位落点，距落点过远转奔跑追赶，落定不重发号令；小队可锚定跟随另一小队（前队质心 − 行进方向 × gap，死区防抖，前队全灭自动解除）。
- **间距不变式**（改数值前必读 formation_spacing.gd 文件头）：碰撞体宽 < 分离半径 < 横向间距 ≤ 列间距；跟队死区 < 横向间距；到位容差 ≥ 2×横向间距。分离半径曾有三份副本且换轨只改到一份，导致分离力持续对抗槽位、队列被推散（"阵型混乱"根因）——此后只在本模块维护、消费方经 api.gd 取值。
- **队伍级共享目标**：每 0.5s 为每个战斗小队选共享攻击目标，队员在攻击行为里优先集火。选型走 tactics `TargetFinder.find_target`（经 `../tactics/api.gd` 的 Finder 常量；缺省 opts = 最近存活敌人，与单测/独立环境语义一致）。
- **权威值择班**：`get_squad_authority` = 班长在场 1.0 + 组织指挥官在册 0.5 + 班长被玩家附身 0.2；`should_switch_squad` 滞回 authority_margin=0.07。自主跳槽（authority_switch_enabled）按宿主节拍周期评估：邻近班权威对比 + 玩家班吸引/黏性加成 + 单位冷却与错峰相位 + 班长放人阈值 + 单拍迁出上限；迁移复用既有 add_unit（组织同步/角色/槽位一次做全）。
- **小队相位计划**（phase_plan_enabled）：推进类号令激活、其余号令撤销（推进类枚举值由装配层注入，见下）；成员分 CORE/SCOUT/左右翼四角色（编队槽位列序 × 素质代理双维），CORE_LEAP→CORE_WAIT→FLANK_LEAP→FLANK_WAIT 交替掩护跃进直至终点；到位容差取 formation_spacing.gd 的 ARRIVE_TOLERANCE（`config/ai/squad_phase_plan.tres` 覆盖）。计划逻辑全在 squad_phase_plan.gd（纯逻辑无自转），本系统只做参数装载/号令触发/节拍驱动/查询出口；跟随玩家或锚定跟队的小队不激活。
- **跨图携带**：export_squads / disband_all_squads / restore_squads（CombatApi 透传，换图前导出、新图按快照重建）。

---

## 装配与消费

- 实例化与挂树在 composition root（`modules/world/scripts/setup/`）：创建 FormationSystem 节点挂 GameRoot，再 `setup(OrganizationApi)`；同一装配步把实例注入 TacticalOrders（tactics）/ CommandChain / BattleDirector 与实体（`set_formation_system`）。
- 战术词汇直取 `../tactics/api.gd` 契约出口：共享目标选型 = `Finder.find_target`，相位计划推进类号令枚举 = `Orders.OrderType`（ADVANCE_ALL / SPRINT，编译期常量对齐，枚举增改无需改本模块）。
- `score` 类查询与号令触发全部经 duck 调用（`has_method` 防护），消费方不 preload 本模块内部脚本。

---

## 相关文档

- 编队/阵列设计：`docs/技术/架构/场景与战斗/场景与战斗架构.md` §8.2（FormationSystem）、§8.3（小队 = L1 组织节点）
- AI 机制族（相位计划/权威值择班的参数与开关）：`docs/设计/系统/12-游戏AI系统.md`、[modules/combat/README.md](../combat/README.md) 的 GK 机制开关族
- 参数档案：`config/balance/variables.tres`（formation 类目）、`config/formations/formation_presets.tres`、`config/ai/squad_phase_plan.tres`、`config/ai/formation_authority.tres`
