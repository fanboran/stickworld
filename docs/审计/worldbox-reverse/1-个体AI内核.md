# WorldBox 逆向·个体 AI 内核（方向①深读笔记）

> **关系**：本文是总档 [`../WorldBox逆向_2026-09-12.md`](../WorldBox逆向_2026-09-12.md) 的细表分章①——逐机制行号与数值以本文为准，总档为合并提炼版。
> **定位**：「游戏 AI 集大成」WorldBox 逆向阶段 2·方向①产出，对应 [`0-代码地图.md`](0-代码地图.md) 深挖点 #1/#2。深读对象：`AiSystem.cs`(403) / `UtilityBasedDecisionSystem.cs`(334) / `DecisionAsset.cs`(168) / `DecisionChecks.cs`(42) / `DecisionHelper.cs`(37) / `NeuroLayer`+`NeuralLayerLibrary` / `DecisionsLibrary.cs`(2188 全扫) / 挂接点（BatchActors、Actor、ActorJobLibrary、BehMakeDecision）。
> 反编译产物：`external/worldbox_decompiled/`（行号为反编译实测）。版权同 0-代码地图：只录机制/数值/行为语义。
>
> **本文全部内容为【提案/待定】**：类名/行号/数值为反编译实测（确定），但「机制判断」「对本项目启示」均为 AI 深读推断，未经创始人确认，引用时不得当作已定设定。

---

## 一、内核架构图（文字版：每帧数据流与调用序）

```
MapBox.updateSimulation → BatchActors 批次系统（c_main = 全体 Actor）
│ [Parallel] prepare → updateParallelChecks（timer_action 倒计时）→ 可见性/统计
│ [Post 段按注册序，每桶先查 !_update_done && !_beh_skip 短路]
├─ u8_checkUpdateTimers   timer_action ≥ 0 → skipUpdates()   【等待期整个 AI 冻结】
├─ b1_checkUnderForce     被外力位移/空中 → skipBehaviour()   【AI 让位物理】
├─ b2_checkCurrentEnemyTarget 已有敌且可打 → skipBehaviour()   【AI 让位战斗】
├─ b3_findEnemyTarget     每 5 帧一跳；找到新敌 → 停止移动 + skipBehaviour()
├─ b4_checkTaskVerifier   当前任务带 verifier 且其 execute==Stop → cancelAllBeh()；
│                         is_moving → skipBehaviour()        【移动期不重入决策】
├─ b5_checkPathMovement   寻路中 → updatePathMovement + skipBehaviour()
├─ b6_0_updateDecision    仅 c_make_decision 容器成员（跑完 Clear()）：
│    └─ DecisionHelper.makeDecisionFor(actor)
│        ├─ isStatsDirty → setTask("wait") 回退，本轮不决策
│        └─ UBDS.useOn(actor)（见下）命中 → pActor.setTask(decision.task_id ?? decision.id)
├─ b55_updateNaturalDeaths 每 20 帧一跳（仅 action_index==0 时可死）
└─ b6_updateAI            ai.update() → AiSystem.run()：
     task==null → updateNewBehJob()：
       ① _scheduled_task_id 非空（scheduleTask 预定）→ 直接置任务
       ② job==null → next_job_delegate()（Actor 按 baby/市民/战士/无城文明随机选岗）
       ③ 顺序取 job.tasks[task_index++]（job.random 则整组洗牌）
       ④ 任务带条件守卫：全部 (谓词==期望) 通过 → 置任务；任一失败 → setTask("nothing")
          （"nothing" 无动作序列 → 下帧立即结束，等于一帧空转后回到岗位序列）
     action = task.list[action_index] → r = action.startExecute(actor) → 按 BehResult 流转
```

**决策内核**（同帧稍后，仅对申请者执行）：

```
BehMakeDecision.execute（"make_decision" 任务的唯一动作）
  → actor.batch.c_make_decision.Add(actor)；return Stop（任务即刻结束，决策延迟到 b6_0 桶）
UBDS.useOn(actor)：
  clear() → 80% 掷骰定 _do_priority_levels（带攻城令的战士强制 true）
  → 注册决策：基础库按身份分桶（animal / civ / city / baby / others）+ ActorAsset.decisions
     + Actor.decisions（王国/城市/氏族/文化/亚种 meta 族逐层附加）
     每条过滤链：层筛（分层模式低于当前最高层者跳过）→ 冷却中？→ 被玩家禁用？
     → isPossible(only_* 族查 DecisionChecks) → action_check_launch(Actor)（失败且
       cooldown_on_launch_failure → 立即入冷却，防止反复探测昂贵条件）
  → calculateFactors：只取最高优先层（或全量）→ weight（静态值或 weight_calculate_custom 委托）
  → chooseBestAction：chance = e^w（randomnessFactor=1）→ sum × rand() → 累加轮盘命中
  → setDecisionCooldown（记录世界时刻）→ 返回 DecisionAsset
```

要点：**决策不发生在 AI tick 内**——AI 动作只"申请"，实际决策在独立桶批量做；job 层极薄（`unit_citizen` 仅 `[make_decision, check_city_destroyed]`，工作岗如 hunter/builder 由决策 `find_city_job` 经 `CitizenJobAsset.unit_job_default` 切岗，`end_job` 动作收尾回 `getNextJob`）。真正多样性全在决策库（127 条）与任务编排（217 个，方向②）。

## 二、机制真值表

| # | 机制 | WorldBox 实现（类:行） | 关键数值真值 | 对本项目启示 |
|---|------|------------------------|--------------|--------------|
| M1 | 决策=事件容器批量处理 | BehMakeDecision.cs:11 + BatchActors.cs:68,392-404 | 每帧仅处理申请者，处理后 `Clear()`；决策与 AI tick 同帧但分桶 | A4：决策不必全员每拍算——行为动作主动申请入队，天然省算力 |
| M2 | softmax 轮盘赌选优 | UBDS.cs:242-263,229-240 | `chance = e^(weight×1.0)`，`pick = rand()×sum(w)`，累加命中；无 argmax | **A4 头号参照**：softmax 轮盘替代 argmax，权重即软优先级 |
| M3 | NeuroLayer 5 层优先 | UBDS.cs:24-51,127-167 | L0_Minimal→L4_Critical；`rand(0.8)`：80% 只算最高层、20% 全量混合；L4(critical) 注册即强制分层 | A4 可借鉴"行为分层+偶尔跨层"，但跳层概率勿硬编码（见 §三 Top1） |
| M4 | 决策冷却系统 | Actor.cs:4911-4946,4930-4939 | `double[] _decision_cooldowns` 按决策 index；cooldown 单位=世界秒（1~300，常见 5/10/60）；**读档时预置随机偏移冷却**（偏移量 0~0.5×cd）防群体同步决策 | A4/A9：冷却挂决策不挂单位；读档/成批出生时错峰预置，比随机扰动更"物理" |
| M5 | 条件过滤预计算 | DecisionChecks.cs:31-41（ref struct） | 8 个布尔（is_hungry/is_fighting/is_adult/is_civ/is_sapient/is_herd/city_in_danger/can_capture）每轮决策一次性求值，127 条决策复用 | A4：行为过滤条件先聚合快照再逐条查，避免逐行为重复取状态 |
| M6 | launch 门禁+失败惩罚 | DecisionAsset.cs:8,30 + UBDS.cs:131-138 | `action_check_launch` 委托失败 → 本轮跳过；`cooldown_on_launch_failure=true` → 失败也入冷却（如 claim_land cd=60、put_out_fire cd=1） | A4：昂贵/高成本行为加"探测失败也冷却"，防反复试探抖动 |
| M7 | 权重真值表 | DecisionsLibrary.cs（127 条全提取） | 区间 0.05~5：run_away 3.1/5（两个变体）、run_to_water_when_on_fire 5、store_resources 3.1、put_out_fire 4、diet_* 0.96~1、random_move 0.2、decide_where_to_sleep 0.05~1、give_tax 2.55、warrior_army_follow_leader 5；**自定义委托代表**：find_city_job 饿 0.3/饥 1/平常 2（饿时降工作权重→先吃饭）；claim_land 2+stewardship/5×0.1；生育 2（达上限 0.1） | A4 default_behavior 数值定标参考：威胁保命 4~5、主业 2~3、习惯 0.5~1、闲逛 0.2；"负需求压主业"写成权重分段而非阈值开关 |
| M8 | 身份分桶注册 | UBDS.cs:78-102 + DecisionsLibrary.cs:2098-2130(linkAssets) | 非 unique 决策按 list_animal/list_civ/list_baby/其余 分 5 桶；unique 决策只挂 ActorAsset/Actor 附加链 | A4：行为池=通用池+身份池+个体附加池（组织/文化可带专属行为，同构于本项目组织 default_behavior） |
| M9 | Job→Task 条件守卫 | AiSystem.cs:77-96,99-132 | 顺序推进 task_index；守卫=(谓词,期望bool) 字典全过才执行，失败→"nothing"一帧空转；random 岗位整组洗牌 | ai_controller 行为状态机可加"守卫失败→空转一帧回队列"的轻量回退，不抛异常不重排 |
| M10 | BehResult 8 态流转 | AiSystem.cs:282-308 | Continue→idx++ / Stop→任务完 / StepBack→idx--(≥0) / RestartTask→idx=0+计 restarts / ImmediateRun→run() 同帧重入 / RepeatStep·Skip·ActiveTaskReturn→原地不动（Skip 常配 forceTask 换任务） | 比本项目行为状态机的 bool 返回值 richer：StepBack/ImmediateRun 支持"退一步重试"与"同帧换任务"，值得在 A4 行为协议里留位 |
| M11 | 等待=冻结而非轮询 | BatchActors.cs:314-325(u8) + BehRandomWait.cs | `timer_action ≥ 0 → skipUpdates()`（整个 b 段全跳）；wait 任务 BehRandomWait(0.5,1.3)/wait5(1,5)/wait10(1,10) 写 timer；倒计时在 Parallel 段做 | A1：等待期连 tick 都不给（不是每帧问"到点没"），分帧成本归零 |
| M12 | AI 让位优先级链 | BatchActors.cs b1~b5 + Actor.cs:9590-9660 | 外力>已有敌>找新敌(5帧)>任务校验>寻路移动，均先于决策与 AI tick；is_moving 期间不重入决策 | A3 对照：战斗抢占不是"打断任务"而是"本帧让位"，任务保持挂起，敌人消失后从断点续跑 |
| M13 | 任务 verifier 每帧校验 | BatchActors.cs:366-377 + BehaviourTaskBase.cs | `task_verifier.execute()==Stop → cancelAllBeh()`；可打断如 fighting 任务的敌人失效检查 | A4：长时间行为配轻量校验器（廉价谓词），失败整任务作废回决策队列 |
| M14 | 决策→任务翻译 | DecisionHelper.cs:5-26 | 命中决策→`setTask(task_id ?? id)`；决策 id 与任务 id 同名约定（127 决策几乎一一对应 217 任务中的子集） | A4：行为项=决策(权重/冷却/过滤)+任务(动作序列)两个资产解耦，同行为可换实现 |
| M15 | 层递进死数据 | NeuralLayerLibrary.cs:11-42 | `chance_to_go_to_next_layer` 0.3/0.2/0.1（L1→L3）定义了但**全工程无读取点**；实际跳层=UBDS 里硬编码 0.8 掷骰 | 反面教材：连作者都弃用的"逐层递进概率"，M3 的 80/20 才是真实现 |

## 三、值得复刻 Top3 与不建议照搬 Top1

**Top1 复刻——softmax 轮盘赌效用选优（M2+M7）**。落点 A4 效用打分。实现要点：① 权重为正浮点，`chance=exp(w)` 后按总和轮盘，杜绝 argmax 的"高权重垄断"（run_away w=5 也会输给低权重行为）；② 静态 weight 之外留 `weight_calculate` 委托钩子，"饿时工作 2→1→0.3" 这类状态调制写成委托不写成 if 链；③ 每行为带 cooldown（秒）+ disabled 开关，选中即入冷却。

**Top2 复刻——决策冷却错峰系统（M4）**。落点 A4/A9。实现要点：① 冷却按"行为 index"存数组，记录世界时刻而非剩余秒（读档零成本）；② 成批生成/读档时预置 `now - rand(0, 0.5×cd)` 的假上次触发时刻，群体决策天然错峰——本项目兵营爆兵后全员同步决策的防齐套问题可直接套用；③ 探测型行为（候选点/候选目标为空）失败也入短冷却，省掉重复探测。

**Top3 复刻——决策事件容器 + 等待冻结（M1+M11）**。落点 A1 节拍与战斗规模化。实现要点：① AI tick 内动作可"申请决策"入队（`c_make_decision.Add`），同帧稍后统一批处理——决策频率=行为自然结束频率，不追加全局节拍器；② 等待行为只写一个 timer 并把该实体标记"本帧不更新"，倒计时放在并行段做；③ 找敌人等昂贵感知单独 5 帧一跳（间隔参数化进 BalanceConfig，对应 A9 决策间隔族）。

**不建议照搬 Top1——NeuroLayer 跳层机制（M3+M15）**。理由：① 真实现是硬编码 80% 只看最高层/20% 全量，两层随机（跳层掷骰 × softmax 轮盘）叠加后行为选择不可解释、难单测难调试——本项目三铁律要求因果可解释，且咬合④已定方差统一走 personality.demand_variance 单旋钮；② "L4 critical 强制分层"这类例外规则开始打补丁（战士带攻城令→强制、critical 层注册→强制）；③ 设计文档里的层间递进概率（chance_to_go_to_next_layer 0.3/0.2/0.1）是死数据，证明"层递进"直觉在工程上没走通。本项目行为集小（A4 是 default_behavior 字段驱动的少量行为），直接 softmax 全量打分+方差扰动即可，不需要优先层。

## 四、深挖遗留（本方向未读完清单）

- `ai.behaviours/BehaviourTaskActorLibrary.cs`（3265 行，217 任务）仅抽查 nothing/fighting/wait/make_decision 等 6 个——任务编排全景属方向②。
- `ai.behaviours/` 228 个 Beh\* 动作与 `ai.behaviours.conditions/` 12 个条件谓词未逐个读（方向②）。
- `Actor.cs`（9702 行）只读决策冷却/AI tick/选岗相关段：`checkEnemyTargets` 找敌细节、`skipBehaviour/skipUpdates/_update_done` 完整置位链、`b2/b3` 战斗抢占语义只读到入口。
- `ActorAsset.cs`（1386 行）decisions 缓存与 job_citizen/job_attacker/job_baby/job_kingdom 数组的装配未读；meta 族（王国/城市/氏族/文化/亚种）decisions_assets 附加链只读到 Actor 侧。
- `Randy.cs` 随机分布族全貌（本方向仅确认 randomChance=random()≤p）。
- `SingleAction.cs`（updateSingleTasks 定时单动作，City AI 在用）未深读。
- `AiSystemCity/AiSystemKingdom` 同内核的 meta 侧用法与 `BehavioursCity/Kingdom` 任务库（组织 AI 对照，方向③）。
- `JobManagerBase.cs/Batch.cs` 并行边界与 `_update_done` 的线程语义（方向④）。
- `SaveManager.cs:1174` 读档预置冷却确认存在；存档侧 `_decision_cooldowns` 序列化格式未核。
