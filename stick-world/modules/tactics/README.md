# tactics —— 战术决策词汇（目标选择 + 战术号令）

战斗域的**共享战术词汇**：目标怎么选（TargetFinder）、号令说什么（TacticalOrders）。
从 combat 聚合迁出（与 formation 同期的域拆分）——units（行为层选目标）、formation
（小队共享目标 + 相位计划号令判定）、combat（战斗编排）三方共用，独立成模块后
三方全部单向依赖，combat⇄units 环（AR-2）根因消除。

## 目录结构

```
modules/tactics/
├── api.gd            # 对外契约：Orders / Finder 脚本常量出口（跨模块 preload 唯一入口）
├── README.md
└── scripts/
    ├── target_finder.gd    # TargetFinder：公共目标选择核心（RefCounted，static 函数库）
    └── tactical_orders.gd  # TacticalOrders：战术号令节点（OrderType 枚举 + issue/issue_to_org）
```

## 机制要点

- **TargetFinder**（反编译参考实装 A，`external/decompiled/legend/dump/legend_AI_core.cs`）：
  `find_target` / `find_weakest_ally` / `find_targets_in_arc`，规则经 opts 链式过滤表达
  （prefer_low_hp / prefer_large / fixate_on / ignore_current_attackers / max_attackers_per_target…）。
  缺省 opts 语义 = 最近存活敌人（faction_id 阵营口径 + battle 存活列表）。
- **TacticalOrders**：OrderType 枚举（ADVANCE_ALL / SPRINT / HOLD_POSITION / RETREAT /
  TAKE_COVER / RALLY）+ issue / issue_to_org 送达；经运行时注入的 formation /
  command_chain / organization 引用回查（`notify_squad_order` / `notify_org_order`），
  **不静态依赖它们**——依赖方向恒为消费方 → tactics。

## 装配与消费

- 跨模块取脚本一律经 `api.gd` 常量（`Orders` / `Finder`），显式 preload 链保 headless
  防御惯例（§七.3）；禁止 preload 本模块 scripts/ 内部文件（audit_deps 越界 preload 棘轮）。
- 装配（world/scripts/setup）：`TacticalOrders` 实例挂 GameRoot，setup 注入
  FormationSystem / CommandChain / OrganizationApi。
- 消费方：units 行为层（behavior_attack / behavior_heal / weapon_mount 的目标选择）、
  formation（小队共享目标 + 相位计划激活判定）、combat（team_ai 号令编排 /
  utility_scorer 映射）、combat UI（battle_panel 号令按钮）。

## 相关文档

- 分层与依赖：`docs/技术/架构/模块依赖关系.md`
- 模块 API 契约：`docs/技术/架构/模块API契约.md`
- 战斗与 AI 架构：`docs/技术/架构/场景与战斗/战斗与AI.md`
