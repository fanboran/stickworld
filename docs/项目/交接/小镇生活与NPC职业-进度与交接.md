# 小镇生活与 NPC 职业：进度与交接

> **用途**：跨会话交接单一入口。新会话恢复本任务从本文件开始读，不重新摸底。
> **任务**：让火柴人各司其职——铁匠在铁匠铺打铁、伐木工伐木、矿工挖矿，"这就是一个很普通的小镇"；NPC 职业化 + 经济自动产出端。愿景锚点：[`docs/设计/系统/12-小镇生活与美术.md`](../../设计/系统/12-小镇生活与美术.md) §三；也是核心循环断点 6（职业断）的修复线（[`核心循环.md`](../../设计/核心循环.md) §7.1）。
> **工作区约定**：worktree `.temp/town-life`（分支 `agent/town-life`，已建好）。**首跑测试前先 `godot --headless --path stick-world --import` 连跑两遍**（否则 fx 类单测假红）。
> **依赖**：铁匠铺工位需要 A 线批次 1 的铁匠铺场景（未到位时可 placeholder 建筑+工位槽先行）。

---

## 侦察结论（2026-09-09 已完成，勿重复摸底）

- **人口现状**：全村 NPC 唯一刷点 `modules/world/scripts/setup/initial_content.gd:58-78`，数量 `game_root.gd:77 const NPC_COUNT=2`——全村 2 人。
- **行为注册**：`modules/units/scripts/ai/ai_controller.gd:94-176` 已注册 idle/wander/work/haul/follow/move/attack/seek_cover/retreat/heal；`WANDER_PROBABILITY=0`（:33）——没派工就原地罚站。
- **工作类型**：`formation_system.gd:65-71` WorkType = COMBAT/BUILD/HAUL/TRANSPORT(物流预留)/**FORAGE(采集预留，空挂)**；预设配置 `config/formations/formation_presets.tres`（战斗班/建造队/劳工队/运输队）。
- **派工逻辑**：`modules/construction/scripts/work_crew_assigner.gd` 工人池 register/try_assign 自动派工（只管建造）；可派工工人 = 注入 ConstructionAPI 的实体。
- **无职业概念**：miner/lumberjack/blacksmith/铁匠/伐木/矿工全库零命中（pickaxe 只是武器 variant）；NPC 不能采集（采集是玩家附身交互专属 `interaction_controller.gd:90`）。
- **资源 API**：`modules/resources/api.gd` → resource_manager.produce/consume/transfer(5% 运输损耗)/get_stock——NPC 产出的入账通道现成。
- **建筑工位**：`building.gd` 契约已有 `Interior(Floor/Props/WorkSlots)` 节点位（A 线批次 1 会先在铁匠铺摆第一个 WorkSlot）。

## 设计要点（AI 提案，实施批次可微调）

- **职业档案（ProfessionDef）**：`{id, name_zh, work_site_def(绑定建筑 def_id), product(res_id 产出), cycle(工作节拍), tool(武器/工具变体), uniform(着装色)}`。村民 spawn 时分配职业（或从待业池招募——与 E 线兵源共用"人口"概念）。
- **采集行为族**：BehaviorHarvest 泛化三种工作循环——走到工位/资源点 → 劳作（动画钩子：打铁锤击/挥斧/挥镐）→ 产物 produce 入 ResourcesApi → 循环。资源点：树（伐木）、矿脉（挖矿，需 B 线装饰层提供矿脉实体或先用现有石头资源点）、铁砧（打铁：矿→锭转化）。
- **生活节律**：P0 简化为工作/休息两态轮换（避免做完整日夜系统）；NPC 空闲时 wander 概率打开，让村子"活"起来。
- **规模**：NPC_COUNT 2 → 8~12 起步（AI 提案待实测；性能基准 196 单位远未触顶）。
- **打铁的"工序"味道**：挖矿产出矿石 → 铁匠在铁匠铺把矿打成铁锭（res_metal_ore → res_iron_ingot）——这条转化链是"古代帝国运行模拟器"（GDD §1.4 生产到工序）的第一个可见缩影。

## 任务分级调度（Pro / Flash × 会话批次）

> 通用验收：`check_godot_errors` 干净 + `run_all.sh` 全绿（ai_behaviors/possession 组必跑）+ 回填本档 + 中文提交。
> 新会话开场白：「继续 小镇生活与NPC职业 批次 N」。

| 批次 | 级别 | 任务 | 依赖 | 验收门 | 新会话必读 |
|---|---|---|---|---|---|
| **1** | Pro | **职业档案系统**：ProfessionDef(.tres/config) + 村民 spawn 职业分配 + 职业着装（身体色/工具变体，pickaxe 已有）+ 待业/在职状态 | 无 | 村里可见不同着装的村民（视觉 Subagent 截图）+ run_all 绿 | 本档侦察结论；`ai_controller.gd` 行为注册 |
| **2** | Pro | **采集行为族（BehaviorHarvest）**：工作循环（寻位→移动→劳作动画钩子→产出入账）三变体（伐木/挖矿/打铁）；树/矿脉资源点实体（ depletion+重生节拍，AI 提案）；打铁=矿→锭转化 | 1 | 集成测试：无人干预 N 分钟后 res_wood/ore/ingot 库存增长；视觉验收（村里有人在干活） | `formation_system.gd` WorkType；`resources/api.gd`；批次 1 落地物（见下） |
| **3** | Pro | **工作场所运转**：WorkSlots 消费（NPC 就近找工位上班；铁砧工位 A 线到位前 placeholder）+ 工作/休息节律 + wander 打开 | 2 | NPC 白天在岗劳作、空闲走动的观感（视觉 Subagent 时间序列截图） | `building.gd` Interior 契约；A 线交接档 |
| **4** | Flash | **人口扩充与配比**：NPC_COUNT 2→8~12、职业配比随建筑走（有铁匠铺才有铁匠）+ 编队征用劳工的互斥（在岗 NPC 被征入伍则离岗） | 3 | 村镇生活感整体验收 + run_all 绿（menu/smoke 组） | E 线兵源设计（人口概念对齐） |

**依赖图**：1 → 2 → 3 → 4；3 与 A 线 1 弱耦合（placeholder 解耦）。

## 进度记录（每批完成后回填）

| 批次 | 状态 | 提交 | 备注 |
|---|---|---|---|
| 1 | ✅ 完成 | 294b9f5d | 三职业着装可见（视觉 Subagent PASS，截图 `stick-world/tests/dev/professions_out.png`）；run_all 绿（3 失败项单跑全绿=并行 flaky，与本批无关） |
| 2 | ⬜ 未开工 | — | |
| 3 | ⬜ 未开工 | — | |
| 4 | ⬜ 未开工 | — | |

## 批次 1 落地物（批次 2 新会话必读）

- **模块**：`modules/town_life/`——`scripts/profession_registry.gd`（ProfessionRegistry：档案读取/轮转分配/着装应用，静态无状态）+ `api.gd`（TownLifeAPI 契约：assign_village_job/get_professions/get_profession）。
- **配置**：`config/town_life/professions.tres`（BalanceResource 行数组；读取照 formation_system 先例直读 .tres 带 static 缓存，不依赖 autoload）。字段 id/name_zh/work_site_def/product/cycle/tool/uniform——work_site_def/product/cycle 已落配置待批次 2/3 消费。
- **实体协议**：`stickman_entity.set_profession/get_profession`（弱类型 id，**空串=待业**；批次 4 征兵离岗走 set_profession("")）。
- **挂接点**：`initial_content.spawn_npcs` 调 `TownLifeAPI.assign_village_job(npc, i)`（轮转 index % 职业数；真实 NPC_COUNT=2 → 只分到铁匠+伐木工）。
- **工具暂代**：铁匠 pickaxe 代锤、伐木工 sword 代斧（TOOL_WEAPONS 映射表在 registry；批次 2 上专属工具模型时只改配置与映射）。
- **资源 id 真名**（resources.tres）：`res_wood / res_stone / res_metal_ore / res_iron_ingot / res_black_asphalt / res_silk`——设计要点里的"res_ore"真名是 **res_metal_ore**。
- **dev 截图场景**：`tests/dev/snapshot_professions.tscn`（真渲染：`godot --path stick-world res://tests/dev/snapshot_professions.tscn`；补 spawn 矿工凑三职业同框 + stdout 打印职业/颜色证据）。
- **已知未验证**：着装色与地图背景在不同时段（夜晚）的对比度未测；NPC_COUNT 扩充在批次 4。

## 关键决策速查

| 决策 | 结论 |
|---|---|
| 职业绑定 | ProfessionDef 绑工作建筑与产物；职业分化靠配置不靠硬编码 |
| 产出通道 | NPC 劳作直接 produce 入 ResourcesApi（与手采/征服奖励同池） |
| 打铁语义 | 矿→锭转化链（GDD"生产到工序"第一个可见缩影） |
| 节律 | P0 工作/休息两态，完整日夜系统不做 |
| 采集归属 | NPC 采集与玩家手采并存（FORAGE 工种从预留转实装） |
