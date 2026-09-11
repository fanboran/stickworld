# 小镇生活与 NPC 职业：进度与交接

> **用途**：跨会话交接单一入口。新会话恢复本任务从本文件开始读，不重新摸底。
> **状态**：**批次 1~4 全部完成**（2026-09-09），待创始人观感验收后收线（分支 `agent/town-life`，worktree `.temp/town-life`）。
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
| 2 | ✅ 完成 | 78e0738e / 6fdb9178 / 865a71bf / c5ebdc9c | 采集经济闭环通：三职业村民无人干预劳作，res_wood/ore/ingot 三库存增长（集成测试 `test_town_life_harvest` PASS，编排方复现 run_all 39/0）；视觉判定 PASS（截图 `tests/dev/harvest_out_0..5.png`）；check_godot_errors 干净 |
| 3 | ✅ 完成 | 518388a5 / 0ca1ae24 | WorkSlots 消费+节律+wander 全落地：真建筑槽位上班/拆毁降级占位（集成 `test_town_life_worksite` 3 用例 PASS）、7~19 时工作节律（夜间收工白天回岗）、村民 wander 职业过滤（战斗单位语义不变）；视觉判定 PASS（`tests/dev/rhythm_day_0..2.png` 白天在岗 / `rhythm_night_0..2.png` 夜间散逛）；run_all 40/0 绿；check_godot_errors 干净 |
| 4 | ✅ 完成 | 5db707bb / 8952781d / 065d40a6 / e518010b | 人口 2→10 配比落地：`assign_village_jobs` 配比分配（铁匠1/伐木3/矿3/待业3，quota+工位容量双约束）、spawn 两簇分布适配 village_a 边界、编队征用离岗互斥（formation duck 清职业+BehaviorHarvest 即时收工）、wander 改身份标志判定+村锚回归（修待业漂出地图）；视觉判定 PASS（`tests/dev/town_overview_0..2.png` / `town_left_0..2.png`）；unit 45/45 绿；check_godot_errors 干净。**四批全部完成、待创始人观感验收后收线**。编排方验收注：批次 4 曾使 selection_formation/battle_ui 稳定挂——NPC 右簇进框致"恰好 3 人"断言失效（测试场地纯净性假设被打破，非生产行为缺陷），已修 e518010b，最终 run_all 40/0 |

## 批次 1 落地物（批次 2 新会话必读）

- **模块**：`modules/town_life/`——`scripts/profession_registry.gd`（ProfessionRegistry：档案读取/轮转分配/着装应用，静态无状态）+ `api.gd`（TownLifeAPI 契约：assign_village_job/get_professions/get_profession）。
- **配置**：`config/town_life/professions.tres`（BalanceResource 行数组；读取照 formation_system 先例直读 .tres 带 static 缓存，不依赖 autoload）。字段 id/name_zh/work_site_def/product/cycle/tool/uniform——work_site_def/product/cycle 已落配置待批次 2/3 消费。
- **实体协议**：`stickman_entity.set_profession/get_profession`（弱类型 id，**空串=待业**；批次 4 征兵离岗走 set_profession("")）。
- **挂接点**：`initial_content.spawn_npcs` 调 `TownLifeAPI.assign_village_job(npc, i)`（轮转 index % 职业数；真实 NPC_COUNT=2 → 只分到铁匠+伐木工）。
- **工具暂代**：铁匠 pickaxe 代锤、伐木工 sword 代斧（TOOL_WEAPONS 映射表在 registry；批次 2 上专属工具模型时只改配置与映射）。
- **资源 id 真名**（resources.tres）：`res_wood / res_stone / res_metal_ore / res_iron_ingot / res_black_asphalt / res_silk`——设计要点里的"res_ore"真名是 **res_metal_ore**。
- **dev 截图场景**：`tests/dev/snapshot_professions.tscn`（真渲染：`godot --path stick-world res://tests/dev/snapshot_professions.tscn`；补 spawn 矿工凑三职业同框 + stdout 打印职业/颜色证据）。
- **已知未验证**：着装色与地图背景在不同时段（夜晚）的对比度未测；NPC_COUNT 扩充在批次 4。

## 批次 2 落地物（批次 3 新会话必读）

- **行为本体**：`modules/units/scripts/ai/behavior_harvest.gd`（BehaviorHarvest，BehaviorBase 子类，行为名 `harvest`）——泛化工作循环：寻位→移动→劳作（`play_attack()` 按武器路由挥镐/挥剑，cycle 节拍一拍一挥+头顶进度条）→产出入账→循环。双模式按职业档案 `work_site_def` 分流：空=资源点模式（resource_node 组内找**最近未枯竭且 `get_resource_id()==product`** 的点，每拍 `harvest()` 实采实入账，采空自动换点/换树）；非空=工位模式（占位定点，`consume→produce` 两步转化，原料不足空拍等待）。行为不引用 world/town_life 内部类，跨模块只走鸭子协议与 TownLifeAPI 契约。
- **决策接线**：`ai_controller.gd` 的 `_try_harvest()`——次序=命令覆盖>战斗>跟随>建造派工(work/haul)>**采集(harvest)>idle**；职责过滤走 `_can_work(WORK_FORAGE)`（FORAGE 从预留转实装）；待业（职业空串）不采集。采集结束（无资源/无工位）回 idle，决策循环稍后自动重试。
- **职业配置新增字段**（`config/town_life/professions.tres`）：`produce_amount`（每拍产出量：采集 20=与玩家手采同速、打铁 6）、`consume_res`/`consume_amount`（铁匠 consume 10 矿/拍）。数值口径全部 [提案/待定]：矿工净增 4/s > 铁匠消耗 2.5/s，三资源可同时增长（集成测试已验证）。
- **资源转换语义**：ResourcesApi 无原子"转换"，铁匠链在行为内两步实现（`consume(res_metal_ore)` 成功才 `produce(res_iron_ingot)`）；region 与玩家手采同账 `test_region`。
- **占位工位**（[提案/待定]）：`ProfessionRegistry.PLACEHOLDER_WORK_SITES = {"smithy_lv1": 1120.0}`（仓库右侧、村民区之间的村道口；Y 运行时取实体地面线+40）。经 `TownLifeAPI.get_placeholder_work_site_x(def)` 查询，未配置返回 NAN=寻位失败。**批次 3 起转为降级路径**（WorkSlots 真槽位优先，无匹配建筑时兜底；详见批次 3 落地物）。
- **资源点重生**（[提案/待定] 数值）：`resource_node.gd` 采空**不再自毁**，转枯竭态（`visible=false`+不可采+挂 REGEN_TIME=90s 单次 Timer）→ `_regrow()` 原地长满（变体/位置不变，modulate 复位）。玩家交互与 NPC 寻位都跳过枯竭点。**已知限制**：枯竭点不进存档（`save_resource_nodes_to_db` 过滤 is_depleted 维持原状），跨存档读回后该点消失、不处于重生倒计时。
- **测试**：单测 `tests/unit/test_behavior_harvest.gd`（7 用例：无职业/资源点循环/采空转寻/工位转化/原料空拍/未知工位/重生翻转，已进 batch_runner 清单）；集成 `tests/integration/test_town_life_harvest.tscn`（摆树/矿在村民旁+补 spawn 矿工 index2+预置 300 矿，轮询 90s 断言三库存增长+harvest 行为；已注册 run_all 清单/150s 超时/affected 映射含 town_life 与 world 分支）。视觉快照 `tests/dev/snapshot_harvest.tscn`（真渲染连拍 6 帧+stdout 职业/行为/目标证据，截图 `harvest_out_0..5.png`）。
- **遗留移交（非本批引入，未修）**：`tests/unit/test_road_walk.gd` 在 Godot 4.7.2 下 parse error（`PackedVector2Array.is_equal_approx` 不存在，bed73553 引入）+ 4 处断言失败（宽度公式 2500 vs 2400/1600 等），被 batch_runner 的类型化赋值吞错掩盖成伪通过——属世界地图线领域，建议该线修复；另 batch_runner `_await_done` 对加载失败套件的 code 收割有同样吞错隐患。`tests/unit/test_profession_registry.gd` 本批已补 `signal test_done` 声明（原缺声明致 emit ERROR）。
- **批次 3 接手提示**：工位模式换 WorkSlots 的替换点=BehaviorHarvest._locate() 工位分支与 PLACEHOLDER_WORK_SITES；观感下一步=工作/休息节律+wander 打开（WANDER_PROBABILITY=0 在 ai_controller）；NPC 采集与玩家手采并存已验证，F3 调试标签可见资源点类型。

## 批次 3 落地物（批次 4 新会话必读）

- **WorkSlots 消费**：`ProfessionRegistry.get_work_site(entity, work_site_def)`（静态，经 `TownLifeAPI` 转发）——扫 **"building" 组**（`building.gd::_ready` 新增加组，resource_node 组先例）取 `def_id` 匹配 + `is_operational()` + 有槽位的**最近建筑最近槽位**；无匹配建筑降级 `PLACEHOLDER_WORK_SITES` 占位表（**表未删除，转为降级路径**）。返回 `{"pos": Vector2, "building": Node2D 或 null}`，无工位返回 `{}`。**pos.y 恒 NAN 约定**：槽位只消费 X（横向工位），Y 由 BehaviorHarvest 按实体地面线 +40 补齐（同 BehaviorHaul 取货点口径——卷轴地图工作站位全在地面带内保证可达）。A 线铁匠铺落地后**无需改任何代码自动切真槽位**（真建筑优先级高于占位表）。
- **建筑存活校验**：BehaviorHarvest 劳作中每帧 `_target_valid()` 校验工位建筑（freed/离树/非 OPERATIONAL 即重寻位）；`_update_working` 的中途失效检查从"仅资源点模式"扩为两模式通用。行为侧新增观测口 `get_worksite_building()`（测试/截图证据）。
- **工作/休息节律**（[提案/待定]）：`ProfessionRegistry.is_work_time(hour=NAN)`——7~19 时在岗（对齐 EnvironmentAPI 光照关键帧早晨 7/黄昏 19），缺省读 `WorldState.game_time`（EnvironmentSystem 每帧推进），hour 参数显式注入（单测）。**game_time<=0（未初始化/无环境系统场景）视为全天工作**——对批次 2 前的测试桩环境零扰动。双层拦截：ai_controller._try_harvest 挡新进（防 enter 即收工抖动）+ BehaviorHarvest.update 收工（在岗村民整点收尾）。
- **wander 打开**（[提案/待定]）：`ai_controller.villager_wander_probability = 0.5`（var 可测试注入）——idle 完成后村民概率 wander；作用域过滤 `_is_villager()`（有 `get_profession` 且非空串；战斗/编队/敌方单位无职业 → 保持 WANDER_PROBABILITY=0 原地待命语义，AI 测试全绿）。决策次序：work > harvest > **wander（仅村民）** > idle。
- **测试**：单测 `tests/unit/test_work_slots_rhythm.gd`（10 用例：节律端点/全局时间注入恢复/建筑进组+marker 收集/双建筑最近槽位/被毁与 def 不匹配降级/真槽位寻位结算/劳作中拆毁降级/_is_villager/节律挡采集/wander 三态，进 batch_runner 清单 44/44 绿）；集成 `tests/integration/test_town_life_worksite.tscn`（真槽位上班+产出/拆毁降级占位续营业/夜间收工白天回岗，单跑与并行均 PASS，已注册 run_all 清单/超时 240s/affected 映射 town_life+units+building_gen 分支）。视觉快照 `tests/dev/snapshot_rhythm.tscn`（真渲染：白天 12 点三职业在岗 `rhythm_day_0..2.png` / 夜间 23 点收工散逛 `rhythm_night_0..2.png`，stdout 逐帧行为证据）。
- **时间敏感套件加固（重要，新增集成套件必读）**：默认 `seconds_per_day=60`（60 现实秒=1 游戏日）下**一个工作日仅 27.5 真实秒**，长窗口套件中途必撞 19 点收工线（批次 2 的 harvest 套件因此在本批 run_all 首跑 TIMEOUT——真实回归非 flaky）。对策：两个 town_life 套件 `_setup_world` 里 `env.set_seconds_per_day(600.0)`（90s 窗口仅推进 3.6 游戏小时）+ 到岗预算放宽（并行争用 ~2.5x）+ 套件超时 240s；节律断言用 `set_time_of_day` 显式拨针不受流速影响。
- **关键决策速查补充**：节律/wander 数值（7~19 时、概率 0.5）全部 [提案/待定] 待创始人观感定稿（其余见主速查表）。
- **已知限制**：夜间画面为 Terraria 级压暗（既有光照设定），村民剪影辨识度低属光照线领域；`PLACEHOLDER_WORK_SITES` 只有 smithy_lv1 一行，新工位职业（如木匠）落地前需补行或等真建筑；worksuite 套件的占位工位断言依赖 X=1120 常量，若占位表迁移需同步。
- **批次 4 接手提示**：NPC_COUNT 扩充在 `game_root.gd`（const NPC_COUNT=2）；职业配比随建筑走可复用 `get_work_site`（无建筑=无该职业工位→分配时降级）；征兵离岗走 `set_profession("")`（批次 1 契约），离岗后 wander 概率自动失效（_is_villager 判空）；wander 概率若需观感调优改 `ai_controller.villager_wander_probability` 单点。

## 批次 4 落地物（收尾批——本线四批全部完成）

- **人口与配比**：`game_root.NPC_COUNT = 10`（[提案/待定]）。`ProfessionRegistry.assign_village_jobs(entities)`（批量配比分配，spawn 正片入口，经 `TownLifeAPI` 转发）：各职业配额 = **min(配置 quota, 工位容量)**——工位容量 `count_work_capacity()` = 真建筑 WorkSlot 槽位累计，无匹配建筑降级占位表按 1 槽兜底（"村子有打铁需求"语义，保持三职业可见），都无 = 0（该职业不上岗）；资源点职业（work_site_def 空）不受工位约束——**资源点存在性不做现场检查**（village_a 硬化区+城墙净空带吃掉全部资源点属 B 线布局阶段问题，不据此砍配比）。配额满的村民待业（`set_profession("")`）。当前配比：铁匠 1 / 伐木 3 / 矿工 3 / 待业 3（`professions.tres` 新增 `quota` 字段 [提案/待定]）。`assign_village_job(entity, index)` 保留原轮转语义为**强制分配**入口（集成套件 `assign_village_job(npc, 2)` 补矿工的用法无需改动）。
- **spawn 分布**（[提案/待定]，适配 village_a/town_siege 布局）：旧公式 `1050+200*i` 在 i≥6 时超 map_right（2160）。新两簇：右簇 i=0~4 `1050+180i`（1050~1770，贴铁匠占位工位/仓库右缘，沿用既有村民区）；左簇 i=5~9 `-250-180(i-5)`（-250~-970，靠左侧资源带方向，伐木/挖矿通勤短）。超界 fallback 保留（含左侧 `map_left+100` 新增防御）。spawn 时打 `is_villager` 标志 + 批量配比分配 + stdout 逐人证据（`[TownLife] 村庄配比: 在职={...} 待业=N` + 每人职业/工位 X/资源点）。
- **村民身份标志（核心语义改造）**：实体新增 `is_villager`（spawn_npcs 写入，duck `set("is_villager", true)`）——批次 3 的 `_is_villager()` 判"职业非空"在引入待业人口后失效（待业村民与被征用士兵职业都是空串，行为语义相反），改为判**"标志 + 不在编队"**（编队查询走 `get_formation_system()` → `is_in_squad`）。效果矩阵：在职村民=wander+harvest；待业村民=wander 不 harvest；被征用前村民（在队）=均无（战斗待命）；无标志实体（士兵/敌方/裸桩）=均无（批次 3 战斗语义保持）。
- **编队征用互斥**：`FormationSystem._requisition_unit()`（duck 检查 `get_profession` 非空则置空）在 `create_squad`/`add_unit` 成员循环调用——最小接线点，不改 E 线领域结构、零 town_life 依赖。劳作中断：`BehaviorHarvest.update` 新增职业清空自查（即时 finish，与节律收工同点位），决策层 `_try_harvest` 同判不会重进。**释放/解散不回岗**（P0 决策：进待业池闲逛，重新分配留给存档/后续招募系统）。
- **wander 村锚回归**（[提案/待定] 数值）：`BehaviorWander` params 新增可选 `anchor_x`/`anchor_radius`（缺省半径 640，回归力 ANCHOR_FORCE=2 与边界规避同模式）——待业村民全天闲逛无锚会累积漂移，实测漂到 X=-2900（超 village_a 地图边界 -2160）。`ai_controller._villager_wander_params()` 传地图 `town_center_world_x`（village_a=0）；不传锚 = 原语义（敌人/其他 wander 调用零影响）。实体新增 `get_map_reference()` 供读取。修复后待业村民活动范围收敛在村内（实测 393~714）。
- **测试**：单测扩至 **45 套件全绿**——`test_profession_registry` 补 3 用例（容量计数三态/批量配比/容量 0 全待业，配比断言与 tres quota 联动）；`test_work_slots_rhythm` 补 3 用例（劳作中清职业即时收工/真建筑容量累计与被毁降级/wander 超锚回归）+ 批次 3 wander 用例适配身份标志（DecisionFixture 加 `is_villager`/`FakeSquadFS` 编队桩）；新套件 `test_requisition_exclusion`（4 用例：create_squad/add_unit 征用清职业、待业与无协议单位安全、解散不回岗，已注册 batch_runner）。
- **视觉验收材料**：`tests/dev/snapshot_town.tscn`（真渲染：village_a 正片 spawn 10 人 + 村内补摆树×3/矿×3——village_a 净空带内无自然资源点，摆点供伐木/挖矿可见；右簇镜头 `town_overview_0..2.png` 工位/伐木/挖矿/闲逛混合 + 左簇镜头 `town_left_0..2.png` 矿工/待业闲逛；stdout 逐帧行为证据）。**判定 PASS**：三职业着装可辨（棕铁匠@工位 1120 / 绿伐木@树 / 灰矿工@矿，挥镐特效+头顶进度条），在岗与闲逛混合，待业村民锚点内活动。
- **run_all 记录**：本批全量 34 通过 / 6 失败（selection_formation / fx_damage_text / esc_key_input / battle_ui / notification_feed / new_game_smoke-TIMEOUT），**6 项逐一单跑全部复绿（exit=0）=并行 flaky**；其中 new_game_smoke 单跑 2/2（60s 持续运行）验证 10 人村庄无性能/崩溃问题，selection_formation 单跑全绿验证征用互斥接线未破坏编队链路。harvest/worksite 集成套件单跑与并行均 PASS（`assign_village_job(npc,2)` 强制分配入口保持兼容，套件零改动）。
- **已知限制 / 移交**：village_a 正片无自然资源点（净空带覆盖全域）→ 正片里伐木/挖矿劳作不可见（村民寻位失败回 idle+wander），观感补全依赖 B 线城镇生成（资源布局）与 A 线铁匠铺（真工位）——配比逻辑已按"资源点存在性由城镇生成线保证"设计，B 线资源到位后零改动生效；待业村民 wander 半径 640 内可能走到城墙/仓库附近穿帮（建筑无碰撞排除，观感可接受）；wander 锚点只锚 X（村庄横向带），Y 仍由地面带约束。
- **收线状态**：**四批全部完成**，本线无待办批次；待创始人观感验收（热闹小镇整体观感 + 配比数值定稿）后按流程收线（worktree remove + 合并 `agent/town-life`）。

## 关键决策速查

| 决策 | 结论 |
|---|---|
| 职业绑定 | ProfessionDef 绑工作建筑与产物；职业分化靠配置不靠硬编码 |
| 产出通道 | NPC 劳作直接 produce 入 ResourcesApi（与手采/征服奖励同池） |
| 打铁语义 | 矿→锭转化链（GDD"生产到工序"第一个可见缩影）；ResourcesApi 无原子转换，行为内 consume→produce 两步 |
| 节律 | P0 工作/休息两态，完整日夜系统不做 |
| 采集归属 | NPC 采集与玩家手采并存（FORAGE 工种从预留转实装） |
| 资源点枯竭 | 采空不自毁：枯竭态（隐藏+不可采）+90s 重生（[提案/待定]）；枯竭点不进存档为已知限制 |
| WorkSlots 接线 | 建筑进 "building" 组 + 鸭子协议查询（不引 construction 内部注册表）；真槽位优先、占位表永久降级；A 线铁匠铺落地零改动自动切换 |
| 节律与 wander | 7~19 时在岗（对齐光照关键帧）+ 村民 idle 后 0.5 概率 wander（[提案/待定]）；wander 仅限有职业村民，战斗/敌方单位语义不变 |
| 村民身份 | 实体 `is_villager` 标志（spawn 写入）与职业解耦：`_is_villager()` = 标志 + 不在编队——待业村民闲逛、被征用前村民战斗待命、士兵/敌方语义不变（批次 4） |
| 职业配比 | 各职业配额 = min(配置 quota, 工位容量)；工位容量 = 真建筑槽位数、占位表兜底按 1 槽（占位计入配比，A 线铁匠铺未到位也保持铁匠可见 [提案/待定]）；资源点职业不做现场资源检查（存在性由城镇生成线保证）；配额外村民进待业池（wander 闲逛） |
| 人口规模 | NPC_COUNT = 10（起步 8~12 中段 [提案/待定]，在岗 7 + 待业 3；性能基准 196 单位远未触顶） |
| 征用互斥 | 编队注册处（create_squad/add_unit）duck 清职业——最小接线点不改 E 线结构；BehaviorHarvest 职业清空自查即时收工；释放/解散不回岗（P0：进待业池，重分配留给后续招募/存档） |
| wander 漂移 | 待业村民全天闲逛会累积漂出地图（实测 -2900 vs 边界 -2160）：BehaviorWander 加可选 anchor_x 锚点回归（半径 640 [提案/待定]），村民锚定 town_center_world_x，不传锚原语义零影响 |
